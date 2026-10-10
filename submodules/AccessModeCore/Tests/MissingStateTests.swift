import XCTest
@testable import AccessModeCore

final class MissingStateTests: XCTestCase {
    func testUnavailablePresenceQueryCannotBeTreatedAsNeverConfigured() throws {
        let f = try VaultFixture(initialize: false)
        f.keys.presenceDenied = true
        XCTAssertThrowsError(try f.store.isConfigured())
        if case .unavailable = AccessRuntimeBootstrap.inspect({ f.store }) {} else { XCTFail("Unknown presence must deny startup") }
        let coordinator = AccessInitialSetupCoordinator(store: f.store)
        XCTAssertThrowsError(try coordinator.prepare())
        var ownerRan = false
        XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321",
            prepareProtectedResources: { ownerRan = true }))
        XCTAssertFalse(ownerRan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
        f.keys.presenceDenied = false
        XCTAssertFalse(try f.store.isConfigured())
    }

    func testFailedOwnerPreparationDoesNotPublishPresenceAndCanRetry() throws {
        let f = try VaultFixture(initialize: false)
        XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321",
            prepareProtectedResources: { throw AccessError.unavailable }))
        XCTAssertNotNil(f.keys.key)
        XCTAssertFalse(try f.keys.hasCommittedState(namespace: "test.fork"))
        XCTAssertFalse(try f.store.isConfigured())
        let receipt = try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321")
        try f.store.finishInitialSetup(receipt)
        XCTAssertTrue(try f.keys.hasCommittedState(namespace: "test.fork"))
        XCTAssertEqual(try f.store.authenticate(pin: "654321").mode, .b)
    }

    func testWitnessWriteFailureAfterFileCommitCannotReturnReceiptOrGrant() throws {
        let f = try VaultFixture(initialize: false)
        f.keys.presenceWriteDenied = true
        var receipt: AccessInitialSetupReceipt?
        XCTAssertThrowsError(receipt = try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321"))
        XCTAssertNil(receipt)
        let committedBytes = try Data(contentsOf: f.file)
        XCTAssertThrowsError(try f.store.isConfigured())
        XCTAssertThrowsError(try f.store.authenticate(pin: "654321"))
        XCTAssertEqual(try Data(contentsOf: f.file), committedBytes)
        f.keys.presenceWriteDenied = false
        let restarted = try f.reopen()
        XCTAssertTrue(try restarted.isConfigured())
        var ownerRan = false
        XCTAssertThrowsError(try restarted.initialize(configuration: f.config, pinA: "111111", pinB: "222222",
            prepareProtectedResources: { ownerRan = true }))
        XCTAssertFalse(ownerRan)
        XCTAssertEqual(try restarted.authenticate(pin: "654321").mode, .b)
        try FileManager.default.removeItem(at: f.file)
        XCTAssertThrowsError(try restarted.isConfigured())
    }

    func testExistingPreWitnessFileMigratesBeforeStateOrAuthenticationIsReturned() throws {
        let f = try VaultFixture()
        let before = try Data(contentsOf: f.file)
        f.keys.committedNamespaces.remove("test.fork") // Isolated fake legacy state.
        XCTAssertTrue(try f.reopen().isConfigured())
        XCTAssertTrue(try f.keys.hasCommittedState(namespace: "test.fork"))
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        f.keys.committedNamespaces.remove("test.fork")
        XCTAssertEqual(try f.reopen().authenticate(pin: "123456").mode, .a)
        XCTAssertTrue(try f.keys.hasCommittedState(namespace: "test.fork"))
        try FileManager.default.removeItem(at: f.file)
        XCTAssertThrowsError(try f.reopen().isConfigured())
    }

    func testLostConfiguredVaultCannotPermitOrdinaryStartupOrOwnerReinitialization() throws {
        let f = try VaultFixture()
        _ = try f.store.authenticate(pin: "654321")
        // Delete only the file in this test's unique temporary fixture.
        try FileManager.default.removeItem(at: f.file)
        let restarted = try f.reopen()
        XCTAssertThrowsError(try restarted.isConfigured())
        if case .unavailable = AccessRuntimeBootstrap.inspect({ restarted }) {} else {
            XCTFail("Lost configuration must retain the startup lock requirement")
        }
        var ownerPreparationRan = false
        XCTAssertThrowsError(try restarted.initialize(configuration: f.config, pinA: "111111", pinB: "222222",
            prepareProtectedResources: { ownerPreparationRan = true }))
        XCTAssertFalse(ownerPreparationRan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
    }

    func testLostTranscriptCannotResetBoundaryOrRecordAnAlreadyEnqueuedSendAgain() throws {
        let f = try TranscriptFixture()
        let b = try f.b()
        let handle = try f.store.begin(chat: f.chat, boundary: f.boundary(), now: f.now, grant: b)
        let local = f.message(-10, namespace: 1)
        _ = try f.store.recordOutgoing(randomID: 777, localID: local, timestamp: f.now,
            now: f.now, handle: handle, grant: b)
        let directory = f.vault.directory.appendingPathComponent("transcripts")
        let file = directory.appendingPathComponent("access-state.v1.enc")
        try FileManager.default.removeItem(at: file)
        let restarted = try RestrictedTranscriptStore(directory: directory, namespace: "test.fork",
            keyProvider: f.vault.keys, credentials: f.vault.store)
        XCTAssertThrowsError(try restarted.begin(chat: f.chat, boundary: f.boundary(1), now: f.now, grant: b))
        XCTAssertThrowsError(try restarted.recordOutgoing(randomID: 777, localID: local, timestamp: f.now,
            now: f.now, handle: handle, grant: b))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
