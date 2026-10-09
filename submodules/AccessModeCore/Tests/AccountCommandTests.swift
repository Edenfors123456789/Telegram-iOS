import XCTest
@testable import AccessModeCore

final class AccountCommandTests: XCTestCase {
    func activated(_ coordinator: AccessModeCoordinator, _ pin: String) throws -> AccessTicket {
        let ticket = try coordinator.beginUnlock(pin: pin)
        try coordinator.completePreparation(ticket)
        return ticket
    }

    func identity(_ fixture: VaultFixture, record: Int64, user: Int64) -> AccountIdentity {
        AccountIdentity(installation: fixture.config.installation, environment: .production, recordID: record, userID: user)
    }

    func testHideRefreshesAuthorityWithoutPINAndRejectsOldUIResults() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let a = try activated(coordinator, "123456")
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 50)
        let refreshed = try coordinator.setHidden(chat, hidden: true, ticket: a)
        XCTAssertEqual(coordinator.state, .preparing(.a))
        XCTAssertThrowsError(try coordinator.withPolicy(a) { $0.visibleAccounts })
        XCTAssertThrowsError(try coordinator.withPolicy(refreshed) { $0.visibleAccounts })
        try coordinator.completePreparation(refreshed)
        XCTAssertEqual(try coordinator.withPolicy(refreshed) { $0.hiddenChatsForManagement }, [chat])
        let b = try activated(coordinator, "654321")
        XCTAssertFalse(try coordinator.withPolicy(b) { $0.discover(chat) })
        XCTAssertEqual(try coordinator.withPolicy(b) { $0.hiddenChatsForManagement }, [])
        XCTAssertThrowsError(try coordinator.setHidden(chat, hidden: false, ticket: b))
        let reopened = try f.reopen()
        let other = AccessModeCoordinator(store: reopened)
        let newA = try activated(other, "123456")
        XCTAssertEqual(try other.withPolicy(newA) { $0.hiddenChatsForManagement }, [chat])
    }

    func testEnrollmentPersistsOwnPoolAndSelectionWithoutPublishingOtherRole() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let a = try activated(coordinator, "123456")
        let permit = try coordinator.beginEnrollment(ticket: a)
        let accountA = identity(f, record: 20, user: 200)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        let addition = try coordinator.completeEnrollment(permit, confirmedAccount: accountA, isPremium: false, ticket: a)
        XCTAssertEqual(addition.decision, .new(.a))
        try coordinator.completePreparation(addition.ticket)
        XCTAssertEqual(try coordinator.withPolicy(addition.ticket) { $0.selectedAccount }, accountA)
        let b = try activated(coordinator, "654321")
        XCTAssertEqual(try coordinator.withPolicy(b) { $0.visibleAccounts }, [f.config.selectedA])
        let permitB = try coordinator.beginEnrollment(ticket: b)
        let accountB = identity(f, record: 30, user: 300)
        try coordinator.bindEnrollment(permitB, provisionalRecordID: 30, ticket: b)
        let addedB = try coordinator.completeEnrollment(permitB, confirmedAccount: accountB, isPremium: false, ticket: b)
        XCTAssertEqual(addedB.decision, .new(.b))
        try coordinator.completePreparation(addedB.ticket)
        let selectedPrimary = try coordinator.selectAccount(f.config.selectedA, ticket: addedB.ticket)
        try coordinator.completePreparation(selectedPrimary)
        let reopened = AccessModeCoordinator(store: try f.reopen())
        let newA = try activated(reopened, "123456")
        XCTAssertEqual(try reopened.withPolicy(newA) { $0.selectedAccount }, accountA)
        XCTAssertFalse(try reopened.withPolicy(newA) { $0.allowsAccount(accountB) })
        XCTAssertThrowsError(try reopened.selectAccount(accountB, ticket: newA))
    }

    func testHiddenCollisionReturnsNeutralFailureWithoutChangingOwnership() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let a = try activated(coordinator, "123456")
        let knownA = identity(f, record: 20, user: 200)
        let permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        let added = try coordinator.completeEnrollment(permit, confirmedAccount: knownA, isPremium: true, ticket: a)
        try coordinator.completePreparation(added.ticket)
        let b = try activated(coordinator, "654321")
        let attempt = try coordinator.beginEnrollment(ticket: b)
        let provisional = identity(f, record: 21, user: 200)
        try coordinator.bindEnrollment(attempt, provisionalRecordID: 21, ticket: b)
        let failed = try coordinator.completeEnrollment(attempt, confirmedAccount: provisional, isPremium: true, ticket: b)
        XCTAssertEqual(failed.decision, .unavailable)
        try coordinator.completePreparation(failed.ticket)
        XCTAssertEqual(try coordinator.withPolicy(failed.ticket) { $0.visibleAccounts }, [f.config.selectedA])
        let newA = try activated(coordinator, "123456")
        XCTAssertTrue(try coordinator.withPolicy(newA) { $0.allowsAccount(knownA) })
        XCTAssertFalse(try coordinator.withPolicy(newA) { $0.allowsAccount(provisional) })
    }

    func testRevokedOrForeignEnrollmentCannotAdoptAnAccount() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let a = try activated(coordinator, "123456")
        let permit = try coordinator.beginEnrollment(ticket: a)
        let b = try activated(coordinator, "654321")
        let proposed = identity(f, record: 20, user: 200)
        XCTAssertThrowsError(try coordinator.completeEnrollment(permit, confirmedAccount: proposed, isPremium: false, ticket: b))
        let freshB = try activated(coordinator, "654321")
        let second = AccessModeCoordinator(store: try f.reopen(), process: .shareExtension)
        let share = try activated(second, "654321")
        XCTAssertThrowsError(try second.beginEnrollment(ticket: share))
        XCTAssertEqual(try coordinator.withPolicy(freshB) { $0.visibleAccounts }, [f.config.selectedA])
        let ownPermit = try coordinator.beginEnrollment(ticket: freshB)
        let wrongInstallation = AccountIdentity(installation: UUID(), environment: .production, recordID: 20, userID: 200)
        XCTAssertThrowsError(try coordinator.completeEnrollment(ownPermit, confirmedAccount: wrongInstallation, isPremium: false, ticket: freshB))
    }

    func testHiddenPremiumCannotRaiseEnrollmentLimitAndRecordCollisionCannotReassign() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        var a = try activated(coordinator, "123456")
        let hiddenPremium = identity(f, record: 20, user: 200)
        let aPermit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(aPermit, provisionalRecordID: 20, ticket: a)
        let addedA = try coordinator.completeEnrollment(aPermit, confirmedAccount: hiddenPremium, isPremium: true, ticket: a)
        a = addedA.ticket
        try coordinator.completePreparation(a)
        var b = try activated(coordinator, "654321")
        for record: Int64 in [30, 40] {
            let permit = try coordinator.beginEnrollment(ticket: b)
            try coordinator.bindEnrollment(permit, provisionalRecordID: record, ticket: b)
            let added = try coordinator.completeEnrollment(permit, confirmedAccount: identity(f, record: record, user: record * 10), isPremium: false, ticket: b)
            XCTAssertEqual(added.decision, .new(.b))
            b = added.ticket
            try coordinator.completePreparation(b)
        }
        let fullPermit = try coordinator.beginEnrollment(ticket: b)
        try coordinator.bindEnrollment(fullPermit, provisionalRecordID: 50, ticket: b)
        let denied = try coordinator.completeEnrollment(fullPermit, confirmedAccount: identity(f, record: 50, user: 500), isPremium: false, ticket: b)
        XCTAssertEqual(denied.decision, .unavailable)
        b = denied.ticket
        try coordinator.completePreparation(b)
        let collisionPermit = try coordinator.beginEnrollment(ticket: b)
        XCTAssertThrowsError(try coordinator.bindEnrollment(collisionPermit, provisionalRecordID: 20, ticket: b))
        let newB = try activated(coordinator, "654321")
        XCTAssertEqual(try coordinator.withPolicy(newB) { $0.visibleAccounts.count }, 3)
    }

    func testFailedManagementCommitReturnsNoRefreshedAuthority() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let a = try activated(coordinator, "123456")
        let oldBytes = try Data(contentsOf: f.file)
        let directoryPath = f.directory.path
        f.keys.onLoad = { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directoryPath) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryPath) }
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 50)
        XCTAssertThrowsError(try coordinator.setHidden(chat, hidden: true, ticket: a))
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertEqual(try Data(contentsOf: f.file), oldBytes)
    }

    func testEnrollmentMustBeBoundToExactProvisionalRecordAndCannotReplay() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        var a = try activated(coordinator, "123456")
        let unbound = try coordinator.beginEnrollment(ticket: a)
        XCTAssertThrowsError(try coordinator.completeEnrollment(unbound, confirmedAccount: identity(f, record: 20, user: 200), isPremium: false, ticket: a))
        a = try activated(coordinator, "123456")
        let permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        // Retrying the same durable binding is harmless.
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        XCTAssertThrowsError(try coordinator.completeEnrollment(permit, confirmedAccount: identity(f, record: 21, user: 200), isPremium: false, ticket: a))
        a = try activated(coordinator, "123456")
        let own = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(own, provisionalRecordID: 22, ticket: a)
        let added = try coordinator.completeEnrollment(own, confirmedAccount: identity(f, record: 22, user: 200), isPremium: false, ticket: a)
        try coordinator.completePreparation(added.ticket)
        XCTAssertThrowsError(try coordinator.completeEnrollment(own, confirmedAccount: identity(f, record: 22, user: 200), isPremium: false, ticket: added.ticket))
        let current = try activated(coordinator, "123456")
        XCTAssertEqual(try coordinator.withPolicy(current) { $0.visibleAccounts.count }, 2)
    }

    func testSameVisibleIdentityUsesExistingAccountAndFailedCommitNeverAdopts() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        var a = try activated(coordinator, "123456")
        let duplicate = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(duplicate, provisionalRecordID: 20, ticket: a)
        let result = try coordinator.completeEnrollment(duplicate, confirmedAccount: identity(f, record: 20, user: 10), isPremium: false, ticket: a)
        XCTAssertEqual(result.decision, .existingVisible(f.config.selectedA))
        a = result.ticket
        try coordinator.completePreparation(a)
        let permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 30, ticket: a)
        let previousBytes = try Data(contentsOf: f.file)
        let directoryPath = f.directory.path
        f.keys.onLoad = { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directoryPath) }
        XCTAssertThrowsError(try coordinator.completeEnrollment(permit, confirmedAccount: identity(f, record: 30, user: 300), isPremium: false, ticket: a))
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertEqual(try Data(contentsOf: f.file), previousBytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryPath)
        f.keys.onLoad = nil
        let reopened = AccessModeCoordinator(store: try f.reopen())
        let newA = try activated(reopened, "123456")
        XCTAssertEqual(try reopened.withPolicy(newA) { $0.visibleAccounts }, [f.config.selectedA])
    }
}
