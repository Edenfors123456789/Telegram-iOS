import XCTest
@testable import AccessModeCore

/// A bound original key needs a server logout only if an authorizing request
/// may have used it. The native route must mark the key durably before sending
/// any such request (QR export included: the server can authorize it later).
final class EnrollmentAuthorizationAttemptTests: XCTestCase {
    private struct Flow {
        let ticket: AccessTicket
        let permit: AccountEnrollmentPermit
    }
    private func key(_ dc: Int32 = 1, _ byte: UInt8 = 0x51) throws -> AccountEnrollmentSessionKey {
        try AccountEnrollmentSessionKey(datacenterID: dc, digest: Data(repeating: byte, count: 32))
    }
    private func flow(_ c: AccessModeCoordinator, record: Int64 = 20, keys: [AccountEnrollmentSessionKey]) throws -> Flow {
        let t = try c.beginUnlock(pin: "123456"); try c.completePreparation(t)
        let permit = try c.beginEnrollment(ticket: t)
        try c.bindEnrollment(permit, provisionalRecordID: record, ticket: t)
        for key in keys { try c.bindEnrollmentSessionKey(permit, sessionKey: key, ticket: t) }
        return Flow(ticket: t, permit: permit)
    }

    func testUnattemptedKeysNeedNoReceipt() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store)
        _ = try flow(c, keys: [try key(), try key(2, 0x52)])
        XCTAssertEqual(try f.store.file.read().version, 6)
        let claim = try XCTUnwrap(c.claimEnrollmentCleanup())
        XCTAssertEqual(try c.enrollmentSessionKeysRequiringRevocation(claim), [])
        try c.acknowledgeEnrollmentCleanup(claim)
        XCTAssertNil(try c.claimEnrollmentCleanup())
    }

    func testAnAttemptedKeyNeedsItsReceiptAndOnlyItsReceipt() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), old = try key(), migrated = try key(2, 0x52)
        let current = try flow(c, keys: [old, migrated])
        try c.markEnrollmentAuthorizationAttempt(current.permit, sessionKey: migrated, ticket: current.ticket)
        let claim = try XCTUnwrap(c.claimEnrollmentCleanup())
        XCTAssertEqual(try c.enrollmentSessionKeysRequiringRevocation(claim), [migrated])
        XCTAssertThrowsError(try c.acknowledgeEnrollmentCleanup(claim)) { XCTAssertEqual($0 as? AccessError, .invalidTransition) }
        try c.recordEnrollmentSessionRevocation(claim, sessionKey: migrated)
        try c.acknowledgeEnrollmentCleanup(claim)
        XCTAssertNil(try c.claimEnrollmentCleanup())
    }

    func testMarkingIsIdempotentAndNeedsABoundKeyAndAnOpenFlow() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), bound = try key()
        let current = try flow(c, keys: [bound])
        try c.markEnrollmentAuthorizationAttempt(current.permit, sessionKey: bound, ticket: current.ticket)
        let marked = try Data(contentsOf: f.file)
        try c.markEnrollmentAuthorizationAttempt(current.permit, sessionKey: bound, ticket: current.ticket)
        XCTAssertEqual(try Data(contentsOf: f.file), marked, "a repeated mark must not write")
        XCTAssertEqual(try f.store.file.read().pendingEnrollmentCleanup?.authorizationAttempts, [bound])
        let share = AccessModeCoordinator(store: f.store, process: .shareExtension)
        XCTAssertThrowsError(try share.markEnrollmentAuthorizationAttempt(current.permit, sessionKey: bound, ticket: current.ticket))
        // An unbound or replaced key refuses, and the refusal fails closed:
        // the flow's ticket is invalidated, so nothing further can be marked.
        XCTAssertThrowsError(try c.markEnrollmentAuthorizationAttempt(current.permit, sessionKey: try key(2), ticket: current.ticket))
        XCTAssertThrowsError(try c.markEnrollmentAuthorizationAttempt(current.permit, sessionKey: bound, ticket: current.ticket))
        let other = try VaultFixture(), d = AccessModeCoordinator(store: other.store), next = try flow(d, keys: [bound])
        XCTAssertThrowsError(try d.markEnrollmentAuthorizationAttempt(next.permit, sessionKey: try key(1, 0x53), ticket: next.ticket))
        XCTAssertEqual(try other.store.file.read().pendingEnrollmentCleanup?.authorizationAttempts, [])
        _ = try XCTUnwrap(c.claimEnrollmentCleanup())
        let before = try Data(contentsOf: f.file)
        // A claimed flow is over: the caller must not send, so marking refuses.
        XCTAssertThrowsError(try c.markEnrollmentAuthorizationAttempt(current.permit, sessionKey: bound, ticket: current.ticket))
        XCTAssertEqual(try Data(contentsOf: f.file), before)
    }

    func testAMarkSurvivesLockAndReopen() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), bound = try key()
        let current = try flow(c, keys: [bound])
        try c.markEnrollmentAuthorizationAttempt(current.permit, sessionKey: bound, ticket: current.ticket)
        try c.lock()
        let reopened = AccessModeCoordinator(store: try f.reopen()), claim = try XCTUnwrap(reopened.claimEnrollmentCleanup())
        XCTAssertEqual(try reopened.enrollmentSessionKeysRequiringRevocation(claim), [bound])
        XCTAssertThrowsError(try reopened.acknowledgeEnrollmentCleanup(claim))
    }

    func testAnUntrackedLedgerStillRequiresEveryBoundKey() throws {
        // A ledger written before tracking existed cannot tell which keys were
        // used for sign-in, so all of them stay required.
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), first = try key(), second = try key(2, 0x52)
        let current = try flow(c, keys: [first, second])
        try f.store.file.transaction { stored, _ in
            stored!.version = 5
            stored!.pendingEnrollmentCleanup!.authorizationAttempts = nil
        }
        let before = try Data(contentsOf: f.file)
        try c.markEnrollmentAuthorizationAttempt(current.permit, sessionKey: first, ticket: current.ticket)
        XCTAssertEqual(try Data(contentsOf: f.file), before, "marking an untracked ledger has nothing to add")
        let claim = try XCTUnwrap(c.claimEnrollmentCleanup())
        XCTAssertEqual(try c.enrollmentSessionKeysRequiringRevocation(claim), [first, second])
        try c.recordEnrollmentSessionRevocation(claim, sessionKey: first)
        XCTAssertThrowsError(try c.acknowledgeEnrollmentCleanup(claim))
        try c.recordEnrollmentSessionRevocation(claim, sessionKey: second)
        try c.acknowledgeEnrollmentCleanup(claim)
    }

    func testMalformedOrDowngradedAttemptsRefuseAccess() throws {
        for corruption in 0 ... 3 {
            let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), bound = try key()
            _ = try flow(c, keys: [bound])
            try f.store.file.transaction { stored, _ in
                switch corruption {
                case 0: stored!.version = 5; stored!.pendingEnrollmentCleanup!.authorizationAttempts = [bound]
                case 1: stored!.pendingEnrollmentCleanup!.authorizationAttempts = [bound, bound]
                case 2: stored!.pendingEnrollmentCleanup!.authorizationAttempts = [try self.key(2)]
                default: stored!.pendingEnrollmentCleanup!.sessionKeys = nil
                }
            }
            XCTAssertThrowsError(try f.store.isConfigured(), "corruption \(corruption)") { XCTAssertEqual($0 as? AccessError, .corrupt) }
        }
    }
}
