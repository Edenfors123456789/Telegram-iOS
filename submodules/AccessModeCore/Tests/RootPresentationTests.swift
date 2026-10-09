import XCTest
@testable import AccessModeCore

private final class RootUI {
    var covered = false
    var root: AccountIdentity?
    var active = true
    var events: [String] = []
    var ready: (() -> Void)?
    var hideError: Error?

    func controller(_ coordinator: AccessModeCoordinator) throws -> AccessRootPresentation {
        try AccessRootPresentation(coordinator: coordinator, isApplicationActive: { self.active },
            showCover: { self.covered = true; self.events.append("cover") },
            discardRoot: { self.root = nil; self.events.append("discard") },
            publishReady: { preparation in
                self.root = preparation.account; self.events.append("ready"); self.ready?()
            }, hideCover: {
                if let error = self.hideError { throw error }
                self.covered = false; self.events.append("uncover")
            })
    }
}

final class RootPresentationTests: XCTestCase {
    func testOnlyMatchingReadyRootCanUncoverAfterAuthentication() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        XCTAssertTrue(ui.covered)
        let token = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        XCTAssertThrowsError(try controller.withActivePolicy { $0.mode })
        XCTAssertTrue(ui.covered)
        try controller.complete(token, preparedAccount: f.config.selectedA)
        XCTAssertEqual(ui.events, ["cover", "discard", "cover", "discard", "ready", "uncover"])
        XCTAssertFalse(ui.covered)
        XCTAssertEqual(try controller.withActivePolicy { $0.mode }, .a)
        XCTAssertThrowsError(try controller.complete(token, preparedAccount: f.config.selectedA))
        XCTAssertFalse(ui.covered)
    }

    func testOldReadyOrCancellationCannotDisturbNewerModeRoot() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let old = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.lock()
        let current = try controller.prepare(coordinator.beginUnlock(pin: "654321"))
        XCTAssertThrowsError(try controller.complete(old, preparedAccount: f.config.selectedA))
        try controller.cancel(old)
        XCTAssertTrue(ui.covered)
        XCTAssertEqual(try controller.withPreparingPolicy(current) { $0.mode }, .b)
        try controller.complete(current, preparedAccount: f.config.selectedB)
        try controller.cancel(current) // Controller dismissal cannot cancel an active root.
        XCTAssertEqual(try controller.withActivePolicy { $0.mode }, .b)
        XCTAssertFalse(ui.covered)
    }

    func testWrongAccountAndInactiveDeliveryStayCoveredAndDiscardRoot() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let first = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        let wrong = AccountIdentity(installation: f.config.installation, environment: .production, recordID: 90, userID: 90)
        XCTAssertThrowsError(try controller.complete(first, preparedAccount: wrong))
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        let second = try controller.prepare(coordinator.beginUnlock(pin: "654321"))
        ui.active = false
        XCTAssertThrowsError(try controller.complete(second, preparedAccount: f.config.selectedB))
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
    }

    func testPersistentLockFailureCannotRetainPublishedRootOrLocalAuthority() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let token = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.complete(token, preparedAccount: f.config.selectedA)
        f.keys.onLoad = {
            XCTAssertTrue(ui.covered)
            XCTAssertNil(ui.root)
            XCTAssertThrowsError(try controller.withActivePolicy { $0.mode })
            throw AccessError.unavailable
        }
        XCTAssertThrowsError(try controller.lock())
        f.keys.onLoad = nil
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertEqual(coordinator.state, .locked)
    }

    func testReentrantInactiveCallbackDuringPublicationNeverUncovers() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let token = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        ui.ready = { try? controller.lock() }
        defer { ui.ready = nil }
        XCTAssertThrowsError(try controller.complete(token, preparedAccount: f.config.selectedA))
        XCTAssertFalse(ui.events.contains("uncover"))
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertEqual(coordinator.state, .locked)
    }

    func testPublicationStorageFailureDiscardsRootAndDeniesAuthority() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let token = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        ui.ready = { f.keys.denied = true }
        defer { ui.ready = nil }
        XCTAssertThrowsError(try controller.complete(token, preparedAccount: f.config.selectedA))
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertThrowsError(try controller.withActivePolicy { $0.mode })
    }

    func testInactivityDuringPublicationDiscardsRootEvenBeforeLifecycleObserverRuns() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let token = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        ui.ready = { ui.active = false }
        defer { ui.ready = nil }
        XCTAssertThrowsError(try controller.complete(token, preparedAccount: f.config.selectedA))
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertEqual(coordinator.state, .locked)
    }

    func testOlderPublicationFailureDoesNotRelockNewerAlreadyReadyMode() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let old = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        var reentrantError: Error?
        ui.ready = {
            ui.ready = nil
            do {
                try controller.lock()
                let current = try controller.prepare(coordinator.beginUnlock(pin: "654321"))
                try controller.complete(current, preparedAccount: f.config.selectedB)
            } catch { reentrantError = error }
        }
        XCTAssertThrowsError(try controller.complete(old, preparedAccount: f.config.selectedA))
        XCTAssertNil(reentrantError)
        XCTAssertFalse(ui.covered)
        XCTAssertEqual(try controller.withActivePolicy { $0.mode }, .b)
    }

    func testInitializationFailureStillInstallsCoverAndDiscardsPriorRoot() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        ui.root = f.config.selectedA
        f.keys.denied = true
        XCTAssertThrowsError(try ui.controller(coordinator))
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertEqual(coordinator.state, .locked)
    }

    func testFailedFinalNativeUncoverDiscardsRootAndRevokesPreparation() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let token = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        ui.hideError = AccessError.unavailable
        XCTAssertThrowsError(try controller.complete(token, preparedAccount: f.config.selectedA))
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertFalse(ui.events.contains("uncover"))
    }

    func testVisibilityMutationCoversBeforeStorageAndRequiresFreshRoot() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let initial = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.complete(initial, preparedAccount: f.config.selectedA)
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 900)
        var observedStorageWrite = false
        f.keys.onLoad = {
            // The preflight policy read precedes the barrier; the subsequent
            // mutation's first read must occur after local authority was detached.
            if !controller.hasActiveRoot {
                observedStorageWrite = true
                XCTAssertTrue(ui.covered)
                XCTAssertNil(ui.root)
            }
        }
        let changed = try controller.setHidden(chat, hidden: true)
        f.keys.onLoad = nil
        XCTAssertTrue(observedStorageWrite)
        XCTAssertTrue(ui.covered)
        XCTAssertThrowsError(try controller.complete(initial, preparedAccount: f.config.selectedA))
        XCTAssertTrue(try controller.withPreparingPolicy(changed) { $0.isMarkedHidden(chat) })
        try controller.complete(changed, preparedAccount: f.config.selectedA)
        let next = try controller.selectAccount(f.config.selectedA)
        XCTAssertTrue(ui.covered)
        try controller.complete(next, preparedAccount: f.config.selectedA)
    }

    func testDeniedOtherRoleSwitchOrBVisibilityActionDoesNotDestroyCurrentAllowedRoot() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let token = try controller.prepare(coordinator.beginUnlock(pin: "654321"))
        try controller.complete(token, preparedAccount: f.config.selectedB)
        let unknown = AccountIdentity(installation: f.config.installation, environment: .production, recordID: 50, userID: 50)
        XCTAssertThrowsError(try controller.selectAccount(unknown))
        XCTAssertThrowsError(try controller.setHidden(ChatIdentity(account: f.config.selectedB, peerNamespace: 0, peerID: 90), hidden: true))
        XCTAssertEqual(try controller.withActivePolicy { $0.mode }, .b)
        XCTAssertFalse(ui.covered)
        XCTAssertEqual(ui.root, f.config.selectedB)
    }
}
