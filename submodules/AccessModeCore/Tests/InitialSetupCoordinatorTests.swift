import XCTest
@testable import AccessModeCore

final class InitialSetupCoordinatorTests: XCTestCase {
    func testSuccessfulInitialSetupFinishesWithoutUnlockAndConsumesItsRequest() throws {
        let f = try VaultFixture(initialize: false)
        let coordinator = AccessInitialSetupCoordinator(store: f.store)
        let request = try coordinator.prepare()
        XCTAssertEqual(coordinator.state, .preparing)
        var initial: AuthenticatedModeGrant?
        try coordinator.execute(request) {
            let receipt = try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321")
            initial = try f.store.authenticate(pin: "123456")
            return receipt
        }
        XCTAssertEqual(coordinator.state, .finished)
        XCTAssertThrowsError(try f.store.configuration(grant: XCTUnwrap(initial)))
        XCTAssertThrowsError(try coordinator.execute(request) { XCTFail("Duplicate initializer"); throw AccessError.unavailable })
        XCTAssertThrowsError(try coordinator.prepare())
        XCTAssertEqual(try f.store.authenticate(pin: "654321").mode, .b)
    }
    func testQueuedCancellationCannotInvokeLegacyPreparationOrDisturbNewRequest() throws {
        let f = try VaultFixture(initialize: false)
        let coordinator = AccessInitialSetupCoordinator(store: f.store)
        let old = try coordinator.prepare()
        coordinator.cancel()
        let current = try coordinator.prepare()
        XCTAssertThrowsError(try coordinator.execute(old) { XCTFail("Cancelled initializer"); throw AccessError.unavailable })
        XCTAssertEqual(coordinator.state, .preparing)
        XCTAssertFalse(try f.store.isConfigured())
        try coordinator.execute(current) { try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321") }
        XCTAssertEqual(coordinator.state, .finished)
    }
    func testExtensionForeignCoordinatorAndDuplicatePreparationAreDenied() throws {
        let f = try VaultFixture(initialize: false)
        let extensionCoordinator = AccessInitialSetupCoordinator(store: f.store, process: .shareExtension)
        XCTAssertThrowsError(try extensionCoordinator.prepare())
        let main = AccessInitialSetupCoordinator(store: f.store)
        let request = try main.prepare()
        XCTAssertThrowsError(try main.prepare())
        let foreign = AccessInitialSetupCoordinator(store: f.store)
        XCTAssertThrowsError(try foreign.execute(request) { XCTFail("Foreign initializer"); throw AccessError.unavailable })
        XCTAssertThrowsError(try extensionCoordinator.execute(request) { XCTFail("Extension initializer"); throw AccessError.unavailable })
        XCTAssertFalse(try f.store.isConfigured())
    }
    func testExistingOrCorruptStateCannotRunOwnerMutationOrBeReset() throws {
        let configured = try VaultFixture()
        let coordinator = AccessInitialSetupCoordinator(store: configured.store)
        XCTAssertThrowsError(try coordinator.prepare())
        let f = try VaultFixture(initialize: false)
        let denied = AccessInitialSetupCoordinator(store: f.store)
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("corrupt-isolated-fixture".utf8).write(to: f.file)
        XCTAssertThrowsError(try denied.prepare())
        XCTAssertEqual(try Data(contentsOf: f.file), Data("corrupt-isolated-fixture".utf8))
    }
    func testFailureEndsPreparationAndRetryCannotReuseOldRequest() throws {
        let f = try VaultFixture(initialize: false)
        let coordinator = AccessInitialSetupCoordinator(store: f.store)
        let old = try coordinator.prepare()
        XCTAssertThrowsError(try coordinator.execute(old) { throw AccessError.unavailable })
        XCTAssertEqual(coordinator.state, .finished)
        XCTAssertFalse(try f.store.isConfigured())
        let current = try coordinator.prepare()
        XCTAssertThrowsError(try coordinator.execute(old) { XCTFail("Old failed initializer"); throw AccessError.unavailable })
        try coordinator.execute(current) { try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321") }
        XCTAssertEqual(coordinator.state, .finished)
    }
    func testVaultCreatedAfterPreparationCannotBeOverwrittenOrHaveNewAuthorityRevoked() throws {
        let f = try VaultFixture(initialize: false)
        let coordinator = AccessInitialSetupCoordinator(store: f.store)
        let request = try coordinator.prepare()
        let other = try f.reopen()
        try other.initialize(configuration: f.config, pinA: "111111", pinB: "222222")
        let fresh = try other.authenticate(pin: "111111")
        XCTAssertThrowsError(try coordinator.execute(request) { XCTFail("Already-created vault initializer"); throw AccessError.unavailable })
        XCTAssertEqual(try other.configuration(grant: fresh), f.config)
        XCTAssertEqual(try f.store.authenticate(pin: "222222").mode, .b)
    }
    func testReentrantCancellationDoesNotFinishOldReceiptOrRevokeFreshAuthority() throws {
        let f = try VaultFixture(initialize: false)
        let coordinator = AccessInitialSetupCoordinator(store: f.store)
        let request = try coordinator.prepare()
        var fresh: AuthenticatedModeGrant?
        XCTAssertThrowsError(try coordinator.execute(request) {
            let receipt = try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321")
            coordinator.cancel()
            fresh = try f.store.authenticate(pin: "123456")
            return receipt
        })
        XCTAssertEqual(coordinator.state, .finished)
        XCTAssertEqual(try f.store.configuration(grant: XCTUnwrap(fresh)), f.config)
    }
}
