import XCTest
@testable import AccessModeCore

final class EnrollmentCleanupCompletionTests: XCTestCase {
    private func ready(_ c: AccessModeCoordinator) throws -> AccessTicket {
        let t = try c.beginUnlock(pin: "123456"); try c.completePreparation(t); return t
    }
    private func key(_ dc: Int32 = 1, _ byte: UInt8 = 0x51) throws -> AccountEnrollmentSessionKey {
        try AccountEnrollmentSessionKey(datacenterID: dc, digest: Data(repeating: byte, count: 32))
    }
    private func owner(_ c: AccessModeCoordinator, record: Int64 = 20, keys: [AccountEnrollmentSessionKey]) throws -> AccountEnrollmentCleanupTicket {
        let t = try ready(c), permit = try c.beginEnrollment(ticket: t)
        try c.bindEnrollment(permit, provisionalRecordID: record, ticket: t)
        for key in keys { try c.bindEnrollmentSessionKey(permit, sessionKey: key, ticket: t) }
        return try XCTUnwrap(c.claimEnrollmentCleanup())
    }
    private func refused(_ body: @autoclosure () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? AccessError, .invalidTransition, file: file, line: line)
        }
    }

    func testAcknowledgmentNeedsAReceiptForEveryBoundKey() throws {
        // Offline fixtures simulate the native verified-server boundary only.
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), first = try key(), second = try key(2, 0x52)
        let claim = try owner(c, keys: [first, second])
        var before = try Data(contentsOf: f.file)
        refused(try c.acknowledgeEnrollmentCleanup(claim))
        XCTAssertEqual(try Data(contentsOf: f.file), before, "a refused acknowledgment must not write")
        try c.recordEnrollmentSessionRevocation(claim, sessionKey: first)
        before = try Data(contentsOf: f.file)
        refused(try c.acknowledgeEnrollmentCleanup(claim))
        XCTAssertEqual(try Data(contentsOf: f.file), before, "one datacenter's result does not cover another")
        XCTAssertEqual(try c.claimEnrollmentCleanup()?.provisionalRecordID, 20)
        try c.recordEnrollmentSessionRevocation(claim, sessionKey: second)
        try c.acknowledgeEnrollmentCleanup(claim)
        XCTAssertNil(try c.claimEnrollmentCleanup())
    }

    func testRefusedAcknowledgmentKeepsOwnershipAndDirectoryAcrossReopen() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), original = try key()
        let claim = try owner(c, keys: [original])
        refused(try c.acknowledgeEnrollmentCleanup(claim))
        try c.lock()
        let reopened = AccessModeCoordinator(store: try f.reopen()), current = try XCTUnwrap(reopened.claimEnrollmentCleanup())
        XCTAssertEqual(current.provisionalRecordID, 20)
        refused(try reopened.acknowledgeEnrollmentCleanup(current))
        XCTAssertNil(try reopened.withUnownedAccountDirectory(recordID: 20) { XCTFail("unconfirmed owner's data deleted"); return true })
        try reopened.recordEnrollmentSessionRevocation(current, sessionKey: original)
        try reopened.acknowledgeEnrollmentCleanup(current)
        XCTAssertNil(try reopened.claimEnrollmentCleanup())
        XCTAssertEqual(reopened.state, .locked)
    }

    func testAnOwnerThatNeverBoundAKeyNeedsNoReceipt() throws {
        // Authorization may use only an already-bound original key, so an owner
        // with no binding never had a server session to revoke.
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store)
        let claim = try owner(c, keys: [])
        XCTAssertEqual(try c.boundEnrollmentSessionKeys(claim), [])
        try c.acknowledgeEnrollmentCleanup(claim)
        XCTAssertNil(try c.claimEnrollmentCleanup())
    }

    func testStaleForeignAndShareAcknowledgmentsStillFailBeforeTheReceiptCheck() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), original = try key()
        let claim = try owner(c, keys: [original])
        try c.recordEnrollmentSessionRevocation(claim, sessionKey: original)
        let foreign = try VaultFixture(), other = AccessModeCoordinator(store: foreign.store)
        let reopened = AccessModeCoordinator(store: try f.reopen()), share = AccessModeCoordinator(store: f.store, process: .shareExtension)
        let before = try Data(contentsOf: f.file)
        for denied in [other, reopened, share] {
            XCTAssertThrowsError(try denied.acknowledgeEnrollmentCleanup(claim))
        }
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        try c.acknowledgeEnrollmentCleanup(claim)
    }
}
