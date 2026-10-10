import XCTest
@testable import AccessModeCore

final class EnrollmentRevocationReceiptTests: XCTestCase {
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
    private func record(_ c: AccessModeCoordinator, _ ticket: AccountEnrollmentCleanupTicket, _ key: AccountEnrollmentSessionKey, file: StaticString = #filePath, line: UInt = #line) {
        // These offline fixtures simulate the native verified-server boundary.
        // They never contact or revoke an actual Telegram authorization.
        do { try c.recordEnrollmentSessionRevocation(ticket, sessionKey: key) }
        catch { XCTFail("exact simulated receipt refused: \(error)", file: file, line: line) }
    }

    func testOnlyRecordedKeysSurviveLockReopenAndDoNotAuthorizeLocalDeletion() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), first = try key(), second = try key(2, 0x52)
        let claim = try owner(c, keys: [first, second])
        record(c, claim, first); record(c, claim, first)
        XCTAssertEqual(try c.confirmedEnrollmentSessionKeys(claim), [first], "do not invent a second DC's result")
        XCTAssertEqual(try f.store.file.read().pendingEnrollmentCleanup?.revokedSessions?.count, 1)
        record(c, claim, second)
        XCTAssertEqual(try f.store.file.read().version, 6)
        try c.lock()
        let reopened = AccessModeCoordinator(store: try f.reopen()), current = try XCTUnwrap(reopened.claimEnrollmentCleanup())
        let before = try Data(contentsOf: f.file)
        XCTAssertEqual(try reopened.confirmedEnrollmentSessionKeys(current), [first, second])
        XCTAssertEqual(try Data(contentsOf: f.file), before, "read must not rewrite receipts")
        XCTAssertThrowsError(try reopened.confirmedEnrollmentSessionKeys(claim))
        XCTAssertNil(try reopened.withUnownedAccountDirectory(recordID: 20) { XCTFail("receipt alone deleted owned data"); return true })
        XCTAssertEqual(reopened.state, .locked)
    }

    func testUnboundReplacementForeignAndShareReceiptsAreDeniedWithoutWrites() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), original = try key()
        let claim = try owner(c, keys: [original]), before = try Data(contentsOf: f.file)
        for invalid in [try key(2), try key(1, 0x53)] {
            XCTAssertThrowsError(try c.recordEnrollmentSessionRevocation(claim, sessionKey: invalid))
        }
        let foreign = try VaultFixture(), other = AccessModeCoordinator(store: foreign.store)
        let reopened = AccessModeCoordinator(store: try f.reopen()), share = AccessModeCoordinator(store: f.store, process: .shareExtension)
        for denied in [other, reopened, share] {
            XCTAssertThrowsError(try denied.recordEnrollmentSessionRevocation(claim, sessionKey: original))
            XCTAssertThrowsError(try denied.confirmedEnrollmentSessionKeys(claim))
        }
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        XCTAssertEqual(try c.confirmedEnrollmentSessionKeys(claim), [])
        let old = try VaultFixture(), oldCoordinator = AccessModeCoordinator(store: old.store), oldClaim = try owner(oldCoordinator, keys: [])
        XCTAssertThrowsError(try oldCoordinator.recordEnrollmentSessionRevocation(oldClaim, sessionKey: original))
        XCTAssertEqual(try oldCoordinator.confirmedEnrollmentSessionKeys(oldClaim), [])
        XCTAssertEqual(try old.store.file.read().version, 3)
    }

    func testDowngradedDuplicateForeignUnboundAndMalformedReceiptsRefuseAccess() throws {
        for corruption in 0 ... 6 {
            let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), original = try key()
            let claim = try owner(c, keys: [original]), valid = EnrollmentSessionRevocationRecord(claimID: claim.claimID, sessionKey: original)
            try f.store.file.transaction { stored, _ in
                stored!.version = corruption == 0 ? 4 : 5
                stored!.pendingEnrollmentCleanup!.revokedSessions = [valid]
                switch corruption {
                case 0: break
                case 1: stored!.pendingEnrollmentCleanup!.revokedSessions = [valid, valid]
                case 2: stored!.pendingEnrollmentCleanup!.revokedSessions = [EnrollmentSessionRevocationRecord(claimID: UUID(), sessionKey: original)]
                case 3: stored!.pendingEnrollmentCleanup!.revokedSessions = [EnrollmentSessionRevocationRecord(claimID: claim.claimID, sessionKey: try key(2))]
                case 4: stored!.pendingEnrollmentCleanup!.revokedSessions = []
                case 5: stored!.pendingEnrollmentCleanup!.claimID = nil
                default:
                    let malformed = try JSONDecoder().decode(AccountEnrollmentSessionKey.self, from: Data("{\"datacenterID\":1,\"digest\":\"AQ==\"}".utf8))
                    stored!.pendingEnrollmentCleanup!.revokedSessions = [EnrollmentSessionRevocationRecord(claimID: claim.claimID, sessionKey: malformed)]
                }
            }
            XCTAssertThrowsError(try f.store.isConfigured()) { XCTAssertEqual($0 as? AccessError, .corrupt) }
            XCTAssertThrowsError(try c.confirmedEnrollmentSessionKeys(claim))
            XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321"))
        }
    }

    func testUnavailableKeyAndFailedWritePreserveBytesForExactRetry() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), original = try key(), claim = try owner(c, keys: [original])
        let before = try Data(contentsOf: f.file)
        f.keys.denied = true
        XCTAssertThrowsError(try c.recordEnrollmentSessionRevocation(claim, sessionKey: original))
        XCTAssertThrowsError(try c.confirmedEnrollmentSessionKeys(claim))
        f.keys.denied = false
        let path = f.directory.path
        defer { f.keys.onLoad = nil; try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        f.keys.onLoad = { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path) }
        XCTAssertThrowsError(try c.recordEnrollmentSessionRevocation(claim, sessionKey: original))
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        f.keys.onLoad = nil; try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        record(c, claim, original)
        XCTAssertEqual(try c.confirmedEnrollmentSessionKeys(claim), [original])
    }

    func testOldReceiptCannotBeAppliedToANewerOwnerEvenWithTheSameKeyDigest() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), original = try key(), old = try owner(c, keys: [original])
        record(c, old, original)
        try c.acknowledgeEnrollmentCleanup(old) // offline component absence fixture
        let current = try owner(c, record: 30, keys: [original]), before = try Data(contentsOf: f.file)
        XCTAssertThrowsError(try c.recordEnrollmentSessionRevocation(old, sessionKey: original))
        XCTAssertThrowsError(try c.confirmedEnrollmentSessionKeys(old))
        XCTAssertEqual(try c.confirmedEnrollmentSessionKeys(current), [])
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        record(c, current, original)
        XCTAssertEqual(try c.confirmedEnrollmentSessionKeys(current), [original])
    }

    func testOwnerPINJournalRecoveryPreservesVersionFiveAndRecordedResults() throws {
        let f = try VaultFixture(), c = AccessModeCoordinator(store: f.store), original = try key(), claim = try owner(c, keys: [original])
        record(c, claim, original)
        let a = try f.store.authenticate(pin: "123456"), plan = Data([0x41, 0x42])
        _ = try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { plan })
        XCTAssertEqual(try f.store.file.read().version, 6)
        let reopened = try f.reopen()
        XCTAssertTrue(try reopened.resumeOwnerPINChange { XCTAssertEqual($0, plan) })
        XCTAssertEqual(try reopened.file.read().version, 6)
        let current = AccessModeCoordinator(store: reopened), currentClaim = try XCTUnwrap(current.claimEnrollmentCleanup())
        XCTAssertEqual(try current.confirmedEnrollmentSessionKeys(currentClaim), [original])
        XCTAssertEqual(current.state, .locked)
    }
}
