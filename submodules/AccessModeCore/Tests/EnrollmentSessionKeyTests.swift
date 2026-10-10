import XCTest
@testable import AccessModeCore

final class EnrollmentSessionKeyTests: XCTestCase {
    private func ready(_ coordinator: AccessModeCoordinator, pin: String = "123456") throws -> AccessTicket {
        let ticket = try coordinator.beginUnlock(pin: pin)
        try coordinator.completePreparation(ticket)
        return ticket
    }
    private func key(_ dc: Int32 = 1, byte: UInt8 = 0x51) throws -> AccountEnrollmentSessionKey {
        try AccountEnrollmentSessionKey(datacenterID: dc, digest: Data(repeating: byte, count: 32))
    }
    func testSessionFingerprintRejectsInvalidDatacenterAndDigestLength() {
        for dc in [Int32(0), Int32(-1)] {
            XCTAssertThrowsError(try AccountEnrollmentSessionKey(datacenterID: dc, digest: Data(repeating: 1, count: 32)))
        }
        for size in [0, 31, 33, 256] {
            XCTAssertThrowsError(try AccountEnrollmentSessionKey(datacenterID: 1, digest: Data(repeating: 1, count: size)))
        }
    }

    func testOriginalDatacenterFingerprintsSurviveLockAndReopenWithoutUnlock() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: -20, environment: .test, ticket: a)
        let first = try key(), next = try key(2, byte: 0x52)
        do {
            try coordinator.bindEnrollmentSessionKey(permit, sessionKey: first, ticket: a)
            try coordinator.bindEnrollmentSessionKey(permit, sessionKey: first, ticket: a)
            try coordinator.bindEnrollmentSessionKey(permit, sessionKey: next, ticket: a)
        } catch { XCTFail("Original keys were not bound: \(error)"); return }
        XCTAssertEqual(try f.store.file.read().version, 4)
        try coordinator.lock()
        let reopened = AccessModeCoordinator(store: try f.reopen())
        let cleanup = try XCTUnwrap(reopened.claimEnrollmentCleanup())
        XCTAssertEqual(try reopened.boundEnrollmentSessionKeys(cleanup), [first, next])
        XCTAssertEqual(reopened.state, .locked)
        XCTAssertThrowsError(try reopened.withPolicy(a) { $0.visibleAccounts })
        // Fingerprint lookup does not complete cleanup or grant any account data.
    }

    func testAnOriginalKeyCannotBeReplacedAndClaimCancelsFurtherBinding() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        let original = try key()
        do { try coordinator.bindEnrollmentSessionKey(permit, sessionKey: original, ticket: a) }
        catch { XCTFail("Original key was not bound: \(error)"); return }
        XCTAssertThrowsError(try coordinator.bindEnrollmentSessionKey(permit, sessionKey: key(byte: 0x52), ticket: a))
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try coordinator.boundEnrollmentSessionKeys(cleanup), [original])
        XCTAssertThrowsError(try coordinator.bindEnrollmentSessionKey(permit, sessionKey: key(2), ticket: a))
        XCTAssertEqual(try coordinator.boundEnrollmentSessionKeys(cleanup), [original])
    }

    func testAnUnboundRecordAndShareCannotBindOriginalSessionKeys() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        XCTAssertThrowsError(try coordinator.bindEnrollmentSessionKey(permit, sessionKey: key(), ticket: a))
        let fresh = try ready(coordinator), next = try coordinator.beginEnrollment(ticket: fresh)
        try coordinator.bindEnrollment(next, provisionalRecordID: 20, ticket: fresh)
        let share = AccessModeCoordinator(store: f.store, process: .shareExtension)
        let s = try ready(share)
        XCTAssertThrowsError(try share.bindEnrollmentSessionKey(next, sessionKey: key(), ticket: s))
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertThrowsError(try share.boundEnrollmentSessionKeys(cleanup))
        do { let keys = try coordinator.boundEnrollmentSessionKeys(cleanup); XCTAssertEqual(keys, []) }
        catch { XCTFail("Old unbound ledger lookup refused: \(error)") }
    }

    func testOldLedgerHasNoInventedSessionKeyAndForeignClaimsCannotReadIt() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        XCTAssertEqual(try f.store.file.read().version, 3)
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        do { let keys = try coordinator.boundEnrollmentSessionKeys(cleanup); XCTAssertEqual(keys, []) }
        catch { XCTFail("Old ledger lookup refused: \(error)") }
        XCTAssertEqual(try f.store.file.read().version, 3)
        let reopened = AccessModeCoordinator(store: try f.reopen())
        XCTAssertThrowsError(try reopened.boundEnrollmentSessionKeys(cleanup))
        XCTAssertEqual(try coordinator.withPolicy(a) { $0.mode }, .a)
    }

    func testInvalidDuplicateOrDowngradedFingerprintStateRefusesAccess() throws {
        for corruption in 0 ... 2 {
            let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
            let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
            try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
            let original = try key()
            try coordinator.bindEnrollmentSessionKey(permit, sessionKey: original, ticket: a)
            try f.store.file.transaction { stored, _ in
                switch corruption {
                case 0: stored!.version = 3
                case 1: stored!.pendingEnrollmentCleanup!.sessionKeys = [original, original]
                default:
                    let invalid = try JSONDecoder().decode(AccountEnrollmentSessionKey.self,
                        from: Data("{\"datacenterID\":1,\"digest\":\"AQ==\"}".utf8))
                    stored!.pendingEnrollmentCleanup!.sessionKeys = [invalid]
                }
            }
            XCTAssertThrowsError(try f.store.isConfigured()) { XCTAssertEqual($0 as? AccessError, .corrupt) }
            XCTAssertThrowsError(try coordinator.claimEnrollmentCleanup())
            XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321"))
        }
    }

    func testOwnerPINRecoveryPreservesVersionFourAndOriginalKeyBindings() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        let original = try key()
        try coordinator.bindEnrollmentSessionKey(permit, sessionKey: original, ticket: a)
        let owner = try f.store.authenticate(pin: "123456"), plan = Data([0x41, 0x42])
        _ = try f.store.beginOwnerPINChange(grant: owner, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { plan })
        XCTAssertEqual(try f.store.file.read().version, 4)
        let reopened = try f.reopen()
        XCTAssertTrue(try reopened.resumeOwnerPINChange { XCTAssertEqual($0, plan) })
        XCTAssertEqual(try reopened.file.read().version, 4)
        let current = AccessModeCoordinator(store: reopened), cleanup = try XCTUnwrap(current.claimEnrollmentCleanup())
        XCTAssertEqual(try current.boundEnrollmentSessionKeys(cleanup), [original])
        XCTAssertEqual(current.state, .locked)
    }
}
