import XCTest
@testable import AccessModeCore

final class JournalRecoveryRequestTests: XCTestCase {
    func testIncompleteAdapterCannotReportSuccessfulRecoveryOrAllowUserAccess() throws {
        let f = try staged()
        let coordinator = AccessModeCoordinator(store: f.store)
        let request = try XCTUnwrap(coordinator.prepareJournalRecovery())
        XCTAssertThrowsError(try coordinator.executeJournalRecovery(request) {})
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertTrue(try f.store.hasPendingOwnerPINChange())
        XCTAssertThrowsError(try coordinator.beginUnlock(pin: "222222"))
    }

    func testReentrantFreshAuthenticationSurvivesOldRecoveryCompletion() throws {
        let f = try staged()
        let coordinator = AccessModeCoordinator(store: f.store)
        let request = try XCTUnwrap(coordinator.prepareJournalRecovery())
        var newer: AccessTicket?
        XCTAssertThrowsError(try coordinator.executeJournalRecovery(request) {
            XCTAssertTrue(try f.store.resumeOwnerPINChange { _ in })
            newer = try coordinator.beginUnlock(pin: "222222")
        })
        XCTAssertEqual(coordinator.state, .preparing(.a))
        try coordinator.completePreparation(XCTUnwrap(newer))
        XCTAssertEqual(coordinator.state, .active(.a))
    }
    private func staged() throws -> VaultFixture {
        let f = try VaultFixture()
        let a = try f.store.authenticate(pin: "123456")
        _ = try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { Data("sealed-test-plan".utf8) })
        return f
    }

    func testStartupRecoveryHoldsPINAndHasNoUserAuthorityThenRequiresFreshPIN() throws {
        let f = try staged()
        let coordinator = AccessModeCoordinator(store: f.store)
        let request = try XCTUnwrap(coordinator.prepareJournalRecovery())
        XCTAssertEqual(coordinator.state, .preparing(.a))
        let presentation = AccessLockPresentation(legacyIsLockable: true, manuallyLocked: true,
            modeState: coordinator.state, modeRootReady: false, coverHeld: true, applicationActive: true)
        XCTAssertTrue(presentation.shouldCover)
        XCTAssertFalse(presentation.shouldCreatePIN)
        try coordinator.executeJournalRecovery(request) {
            XCTAssertTrue(try f.store.resumeOwnerPINChange { _ in })
        }
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertThrowsError(try coordinator.executeJournalRecovery(request) { XCTFail("Consumed recovery") })
        XCTAssertNil(try coordinator.prepareJournalRecovery())
        let fresh = try coordinator.beginUnlock(pin: "222222")
        XCTAssertEqual(coordinator.state, .preparing(.a))
        try coordinator.completePreparation(fresh)
        XCTAssertEqual(try coordinator.withPolicy(fresh) { $0.mode }, .a)
    }

    func testCancelledRecoveryCannotExecuteOrDisturbNewerRequest() throws {
        let f = try staged()
        let coordinator = AccessModeCoordinator(store: f.store)
        let old = try XCTUnwrap(coordinator.prepareJournalRecovery())
        try coordinator.lock()
        let current = try XCTUnwrap(coordinator.prepareJournalRecovery())
        XCTAssertThrowsError(try coordinator.executeJournalRecovery(old) { XCTFail("Old recovery") })
        XCTAssertEqual(coordinator.state, .preparing(.a))
        try coordinator.executeJournalRecovery(current) { XCTAssertTrue(try f.store.resumeOwnerPINChange { _ in }) }
        XCTAssertEqual(coordinator.state, .locked)
    }

    func testFailedRecoveryRemainsDeniedAndCanPrepareANewRetry() throws {
        let f = try staged()
        let coordinator = AccessModeCoordinator(store: f.store)
        let request = try XCTUnwrap(coordinator.prepareJournalRecovery())
        XCTAssertThrowsError(try coordinator.executeJournalRecovery(request) { throw AccessError.unavailable })
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertTrue(try f.store.hasPendingOwnerPINChange())
        XCTAssertThrowsError(try coordinator.beginUnlock(pin: "654321"))
        let retry = try XCTUnwrap(coordinator.prepareJournalRecovery())
        try coordinator.executeJournalRecovery(retry) { XCTAssertTrue(try f.store.resumeOwnerPINChange { _ in }) }
        XCTAssertFalse(try f.store.hasPendingOwnerPINChange())
    }

    func testRecoveryCannotBeStartedByExtensionOrWhileNormalRootHasAuthority() throws {
        let f = try staged()
        let extensionCoordinator = AccessModeCoordinator(store: f.store, process: .shareExtension)
        XCTAssertThrowsError(try extensionCoordinator.prepareJournalRecovery())
        XCTAssertEqual(extensionCoordinator.state, .locked)
        let ordinary = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: ordinary.store)
        XCTAssertNil(try coordinator.prepareJournalRecovery())
        let ticket = try coordinator.beginUnlock(pin: "123456")
        try coordinator.completePreparation(ticket)
        XCTAssertThrowsError(try coordinator.prepareJournalRecovery())
        XCTAssertEqual(coordinator.state, .active(.a))
    }
}
