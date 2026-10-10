import XCTest
@testable import AccessModeCore

final class EnrollmentCleanupTests: XCTestCase {
    func testCorruptOwnershipOrMissingNewSchemaLedgerNeverFallsBackToSetup() throws {
        for mutation in 0 ... 3 {
            let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
            let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
            try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
            try f.store.file.transaction { stored, _ in
                let owner = stored!.pendingEnrollmentCleanup!
                switch mutation {
                case 0:
                    stored!.pendingEnrollmentCleanup = PendingEnrollmentCleanup(flowID: owner.flowID, installation: owner.installation,
                        mode: owner.mode, provisionalRecordID: f.config.selectedA.recordID, environment: owner.environment, claimID: nil)
                case 1: stored!.pendingEnrollmentCleanup = nil
                case 2: stored!.pendingEnrollment!.provisionalRecordID = nil
                default: stored!.version = 2
                }
            }
            XCTAssertThrowsError(try f.store.isConfigured()) { XCTAssertEqual($0 as? AccessError, .corrupt) }
            XCTAssertThrowsError(try coordinator.claimEnrollmentCleanup())
            XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321"))
        }
    }
    func testFailedClaimAndAcknowledgmentKeepExactDurableOwnerBytesForRetry() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        let path = f.directory.path
        defer { f.keys.onLoad = nil; try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        var before = try Data(contentsOf: f.file)
        f.keys.onLoad = { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path) }
        XCTAssertThrowsError(try coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        f.keys.onLoad = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        guard let owned = try cleanup(coordinator) else { return }
        before = try Data(contentsOf: f.file)
        f.keys.onLoad = { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path) }
        XCTAssertThrowsError(try coordinator.acknowledgeEnrollmentCleanup(owned))
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        f.keys.onLoad = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, 20)
        try coordinator.acknowledgeEnrollmentCleanup(owned)
    }

    func testOwnerPINJournalDoesNotDowngradeOrLoseCleanupAcrossItsRecovery() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        let owner = try f.store.authenticate(pin: "123456")
        let plan = Data([0x41, 0x42, 0x43])
        _ = try f.store.beginOwnerPINChange(grant: owner, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { plan })
        XCTAssertEqual(try f.store.file.read().version, 3)
        let restarted = try f.reopen(), current = AccessModeCoordinator(store: restarted)
        XCTAssertTrue(try restarted.resumeOwnerPINChange { XCTAssertEqual($0, plan) })
        XCTAssertEqual(try restarted.file.read().version, 3)
        guard let owned = try cleanup(current) else { return }
        XCTAssertEqual(owned.provisionalRecordID, 20)
        try current.acknowledgeEnrollmentCleanup(owned)
        XCTAssertEqual(try current.withPolicy(ready(current, pin: "222222")) { $0.visibleAccounts }, [f.config.selectedA])
    }
    func testEnvironmentIsBoundBeforeConfirmedIdentityAndMismatchCannotAdopt() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: -20, environment: .test, ticket: a)
        XCTAssertThrowsError(try coordinator.completeEnrollment(permit, confirmedAccount: identity(f, record: -20, user: 200), isPremium: false, ticket: a))
        guard let owned = try cleanup(coordinator) else { return }
        XCTAssertEqual(owned.environment, .test); XCTAssertEqual(owned.provisionalRecordID, -20)
        try coordinator.acknowledgeEnrollmentCleanup(owned)
        XCTAssertEqual(try coordinator.withPolicy(ready(coordinator)) { $0.visibleAccounts }, [f.config.selectedA])
    }

    func testAnExistingMemberRecordCannotAcquireProvisionalCleanupOwnership() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        XCTAssertThrowsError(try coordinator.bindEnrollment(permit, provisionalRecordID: f.config.selectedA.recordID, ticket: a))
        XCTAssertNil(try coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try coordinator.withPolicy(ready(coordinator)) { $0.visibleAccounts }, [f.config.selectedA])
    }

    func testOtherRoleCollisionRetainsItsMembershipAndOnlyTheNewSessionNeedsCleanup() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), first = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(first, provisionalRecordID: 20, ticket: a)
        let knownA = identity(f, record: 20, user: 200)
        _ = try coordinator.completeEnrollment(first, confirmedAccount: knownA, isPremium: false, ticket: a)
        let b = try ready(coordinator, pin: "654321"), duplicate = try coordinator.beginEnrollment(ticket: b)
        try coordinator.bindEnrollment(duplicate, provisionalRecordID: 21, ticket: b)
        let refused = try coordinator.completeEnrollment(duplicate, confirmedAccount: identity(f, record: 21, user: 200), isPremium: false, ticket: b)
        XCTAssertEqual(refused.decision, .unavailable)
        guard let owned = try cleanup(coordinator) else { return }
        XCTAssertEqual(owned.provisionalRecordID, 21)
        try coordinator.acknowledgeEnrollmentCleanup(owned)
        XCTAssertEqual(try coordinator.withPolicy(ready(coordinator, pin: "654321")) { $0.visibleAccounts }, [f.config.selectedA])
        XCTAssertTrue(try coordinator.withPolicy(ready(coordinator)) { $0.allowsAccount(knownA) })
    }
    private func ready(_ coordinator: AccessModeCoordinator, pin: String = "123456") throws -> AccessTicket {
        let ticket = try coordinator.beginUnlock(pin: pin)
        try coordinator.completePreparation(ticket)
        return ticket
    }
    private func cleanup(_ coordinator: AccessModeCoordinator, file: StaticString = #filePath, line: UInt = #line) throws -> AccountEnrollmentCleanupTicket? {
        let ticket = try coordinator.claimEnrollmentCleanup()
        if ticket == nil { XCTFail("Bound provisional cleanup authority was lost", file: file, line: line) }
        return ticket
    }
    private func identity(_ f: VaultFixture, record: Int64, user: Int64) -> AccountIdentity {
        AccountIdentity(installation: f.config.installation, environment: .production, recordID: record, userID: user)
    }

    func testExactSignedCleanupOwnershipSurvivesLockAndReopenWithoutGrantingAnUnlock() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: -20, ticket: a)
        try coordinator.lock()
        let reopened = AccessModeCoordinator(store: try f.reopen())
        guard let owned = try cleanup(reopened) else { return }
        XCTAssertEqual(owned.provisionalRecordID, -20); XCTAssertEqual(owned.environment, .production)
        XCTAssertEqual(reopened.state, .locked)
        XCTAssertThrowsError(try reopened.withPolicy(a) { $0.visibleAccounts })
        try reopened.acknowledgeEnrollmentCleanup(owned)
        XCTAssertNil(try reopened.claimEnrollmentCleanup())
        XCTAssertEqual(reopened.state, .locked)
        XCTAssertEqual(try reopened.withPolicy(ready(reopened)) { $0.visibleAccounts }, [f.config.selectedA])
    }

    func testCancellationPreservesBoundCleanupButUnboundCancellationCreatesNoOwner() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), unbound = try coordinator.beginEnrollment(ticket: a)
        try coordinator.cancelEnrollment(unbound, ticket: a)
        XCTAssertNil(try coordinator.claimEnrollmentCleanup())
        let bound = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(bound, provisionalRecordID: 20, ticket: a)
        try coordinator.cancelEnrollment(bound, ticket: a)
        guard let owned = try cleanup(coordinator) else { return }
        XCTAssertEqual(owned.provisionalRecordID, 20)
        XCTAssertThrowsError(try coordinator.beginEnrollment(ticket: a))
        try coordinator.acknowledgeEnrollmentCleanup(owned)
        let fresh = try ready(coordinator)
        XCTAssertNoThrow(try coordinator.beginEnrollment(ticket: fresh))
    }

    func testClaimCancelsOldCompletionAndReplayCannotAcknowledgeANewerOwner() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        guard let old = try cleanup(coordinator) else { return }
        XCTAssertThrowsError(try coordinator.completeEnrollment(permit, confirmedAccount: identity(f, record: 20, user: 200), isPremium: false, ticket: a))
        try coordinator.acknowledgeEnrollmentCleanup(old)
        let fresh = try ready(coordinator), next = try coordinator.beginEnrollment(ticket: fresh)
        try coordinator.bindEnrollment(next, provisionalRecordID: 30, ticket: fresh)
        guard let current = try cleanup(coordinator) else { return }
        XCTAssertThrowsError(try coordinator.acknowledgeEnrollmentCleanup(old))
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, 30)
        try coordinator.acknowledgeEnrollmentCleanup(current)
    }

    func testReopenedAndForeignInstancesCannotAcknowledgeEachOthersCleanupTickets() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        guard let old = try cleanup(coordinator) else { return }
        let reopened = AccessModeCoordinator(store: try f.reopen())
        guard let current = try cleanup(reopened) else { return }
        XCTAssertThrowsError(try reopened.acknowledgeEnrollmentCleanup(old))
        let other = try VaultFixture(), foreign = AccessModeCoordinator(store: other.store)
        XCTAssertThrowsError(try foreign.acknowledgeEnrollmentCleanup(current))
        XCTAssertNil(try foreign.claimEnrollmentCleanup())
        XCTAssertEqual(try reopened.claimEnrollmentCleanup()?.provisionalRecordID, 20)
        try reopened.acknowledgeEnrollmentCleanup(current)
    }

    func testSuccessfullyAdoptedMembershipHasNoCleanupAuthority() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        let adopted = identity(f, record: 20, user: 200)
        let result = try coordinator.completeEnrollment(permit, confirmedAccount: adopted, isPremium: false, ticket: a)
        XCTAssertEqual(result.decision, .new(.a))
        XCTAssertNil(try coordinator.claimEnrollmentCleanup())
        try coordinator.completePreparation(result.ticket)
        XCTAssertTrue(try coordinator.withPolicy(result.ticket) { $0.allowsAccount(adopted) })
    }

    func testDuplicateVisibleIdentityKeepsOnlyItsOwnProvisionalCleanupRecord() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        let result = try coordinator.completeEnrollment(permit, confirmedAccount: identity(f, record: 20, user: 10), isPremium: false, ticket: a)
        XCTAssertEqual(result.decision, .existingVisible(f.config.selectedA))
        guard let owned = try cleanup(coordinator) else { return }
        XCTAssertEqual(owned.provisionalRecordID, 20); XCTAssertNotEqual(owned.provisionalRecordID, f.config.selectedA.recordID)
        try coordinator.acknowledgeEnrollmentCleanup(owned)
        let fresh = try ready(coordinator)
        XCTAssertEqual(try coordinator.withPolicy(fresh) { $0.visibleAccounts }, [f.config.selectedA])
    }

    func testShareProcessCannotClaimOrAcknowledgeMainProvisionalCleanup() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        guard let owned = try cleanup(coordinator) else { return }
        let share = AccessModeCoordinator(store: try f.reopen(), process: .shareExtension)
        XCTAssertThrowsError(try share.claimEnrollmentCleanup())
        XCTAssertThrowsError(try share.acknowledgeEnrollmentCleanup(owned))
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, 20)
        try coordinator.acknowledgeEnrollmentCleanup(owned)
    }
}
