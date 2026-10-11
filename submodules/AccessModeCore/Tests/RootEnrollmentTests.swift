import XCTest
@testable import AccessModeCore

private final class EnrollmentRootUI {
    var covered = false
    var root: AccountIdentity?
    var active = true

    func controller(_ coordinator: AccessModeCoordinator) throws -> AccessRootPresentation {
        try AccessRootPresentation(coordinator: coordinator, isApplicationActive: { self.active },
            showCover: { self.covered = true }, discardRoot: { self.root = nil },
            publishReady: { self.root = $0.account }, hideCover: { self.covered = false })
    }
}

/// Completing an enrollment changes the configuration, so it runs as a root
/// transition: covered and detached before the write, then a fresh root.
final class RootEnrollmentTests: XCTestCase {
    private func identity(_ f: VaultFixture, _ record: Int64, user: Int64) -> AccountIdentity {
        AccountIdentity(installation: f.config.installation, environment: .production, recordID: record, userID: user)
    }
    private func started(_ coordinator: AccessModeCoordinator, _ controller: AccessRootPresentation, pin: String, account: AccountIdentity,
        record: Int64) throws -> (AccessRootPreparation, AccountEnrollmentPermit) {
        let root = try controller.prepare(coordinator.beginUnlock(pin: pin))
        try controller.complete(root, preparedAccount: account)
        let permit = try coordinator.beginEnrollment(ticket: root.ticket)
        try coordinator.bindEnrollment(permit, provisionalRecordID: record, ticket: root.ticket)
        return (root, permit)
    }

    func testANewAccountIsAddedUnderCoverAndBecomesTheFreshRoot() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store), ui = EnrollmentRootUI()
        let controller = try ui.controller(coordinator)
        let (_, permit) = try started(coordinator, controller, pin: "123456", account: f.config.selectedA, record: 30)
        let added = identity(f, 30, user: 30)
        var wroteWhileCovered = false
        f.keys.onLoad = { if !controller.hasActiveRoot { wroteWhileCovered = ui.covered && ui.root == nil } }
        let (decision, preparation) = try controller.completeEnrollment(permit, confirmedAccount: added, isPremium: false)
        f.keys.onLoad = nil
        XCTAssertTrue(wroteWhileCovered)
        XCTAssertEqual(decision, .new(.a))
        XCTAssertEqual(preparation.account, added)
        XCTAssertTrue(ui.covered)
        try controller.complete(preparation, preparedAccount: added)
        XCTAssertEqual(ui.root, added)
        XCTAssertTrue(try controller.withActivePolicy { $0.allowsAccount(added) })
        XCTAssertNil(try coordinator.claimEnrollmentCleanup(), "a new membership resolves the provisional owner")
    }

    func testAnAccountOfTheOtherModeIsRefusedNeutrallyAndKeepsCleanup() throws {
        let f = try VaultFixture(initialize: false), shared = f.config.selectedA
        let onlyA = identity(f, -12, user: 12)
        let config = try AccessConfiguration(installation: f.config.installation, accounts: [
            AccountMembership(identity: shared, ownership: .shared), AccountMembership(identity: onlyA, ownership: .a)
        ], selectedA: onlyA, selectedB: shared)
        try f.store.initialize(configuration: config, pinA: "123456", pinB: "654321")
        let coordinator = AccessModeCoordinator(store: f.store), ui = EnrollmentRootUI(), controller = try ui.controller(coordinator)
        let (_, permit) = try started(coordinator, controller, pin: "654321", account: shared, record: 40)
        // B signs in to A's hidden account: same user, new provisional record.
        let (decision, preparation) = try controller.completeEnrollment(permit, confirmedAccount: identity(f, 40, user: 12), isPremium: false)
        XCTAssertEqual(decision, .unavailable)
        XCTAssertEqual(preparation.account, shared, "B stays on its own account")
        try controller.complete(preparation, preparedAccount: shared)
        XCTAssertFalse(try controller.withActivePolicy { $0.allowsAccount(onlyA) })
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, 40, "only the new session is cleaned up")
    }

    func testAnEnrollmentFromAnOlderRootCannotComplete() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store), ui = EnrollmentRootUI()
        let controller = try ui.controller(coordinator)
        let (_, permit) = try started(coordinator, controller, pin: "123456", account: f.config.selectedA, record: 30)
        let changed = try controller.setHidden(ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 900), hidden: true)
        try controller.complete(changed, preparedAccount: f.config.selectedA)
        XCTAssertThrowsError(try controller.completeEnrollment(permit, confirmedAccount: identity(f, 30, user: 30), isPremium: false))
        XCTAssertTrue(ui.covered)
        XCTAssertFalse(controller.hasActiveRoot)
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, 30)
    }

    func testAnInactiveAppOrALockedRootCannotComplete() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store), ui = EnrollmentRootUI()
        let controller = try ui.controller(coordinator)
        let (_, permit) = try started(coordinator, controller, pin: "123456", account: f.config.selectedA, record: 30)
        ui.active = false
        XCTAssertThrowsError(try controller.completeEnrollment(permit, confirmedAccount: identity(f, 30, user: 30), isPremium: false))
        XCTAssertTrue(ui.covered)
        XCTAssertFalse(controller.hasActiveRoot)
        ui.active = true
        XCTAssertThrowsError(try controller.completeEnrollment(permit, confirmedAccount: identity(f, 30, user: 30), isPremium: false))
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, 30)
    }
}
