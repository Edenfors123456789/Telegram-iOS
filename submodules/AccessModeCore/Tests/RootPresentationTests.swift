import XCTest
@testable import AccessModeCore

private final class RootUI {
    var covered = false
    var root: AccountIdentity?
    var active = true
    var events: [String] = []
    var ready: (() -> Void)?
    var cover: (() -> Void)?
    var hideError: Error?
    var authorize: (AccessModePolicy) throws -> Void = { _ in }

    func controller(_ coordinator: AccessModeCoordinator) throws -> AccessRootPresentation {
        try AccessRootPresentation(coordinator: coordinator, isApplicationActive: { self.active },
            authorizeRoot: { try self.authorize($0) },
            showCover: { self.covered = true; self.events.append("cover"); self.cover?() },
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
    private func action(_ controller: AccessRootPresentation, _ chat: ChatIdentity, file: StaticString = #filePath, line: UInt = #line) -> AccessChatVisibilityAction? {
        do { return try controller.makeChatVisibilityAction(chat) }
        catch { XCTFail("Current A action refused: \(error)", file: file, line: line); return nil }
    }

    func testVisibilityMenuActionCoversBeforeMutationAndCannotReplay() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store), ui = RootUI()
        let controller = try ui.controller(coordinator)
        let initial = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.complete(initial, preparedAccount: f.config.selectedA)
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 3, peerID: -42)
        guard let hide = action(controller, chat) else { return }
        XCTAssertFalse(hide.isHidden); XCTAssertFalse(ui.covered)
        var sawCoveredWrite = false
        f.keys.onLoad = {
            if !controller.hasActiveRoot { sawCoveredWrite = true; XCTAssertTrue(ui.covered); XCTAssertNil(ui.root) }
        }
        let changed: AccessRootPreparation
        do { changed = try controller.performChatVisibilityAction(hide) }
        catch { f.keys.onLoad = nil; XCTFail("Current action did not execute: \(error)"); return }
        f.keys.onLoad = nil
        XCTAssertTrue(sawCoveredWrite); XCTAssertTrue(ui.covered); XCTAssertNil(ui.root)
        XCTAssertThrowsError(try controller.performChatVisibilityAction(hide))
        try controller.complete(changed, preparedAccount: f.config.selectedA)
        XCTAssertThrowsError(try controller.performChatVisibilityAction(hide)); XCTAssertFalse(ui.covered)
        guard let show = action(controller, chat) else { return }
        XCTAssertTrue(show.isHidden)
        let shown = try controller.performChatVisibilityAction(show)
        try controller.complete(shown, preparedAccount: f.config.selectedA)
        XCTAssertFalse(try controller.withActivePolicy { $0.isMarkedHidden(chat) })
    }

    func testOldAVisibilityMenuCannotActAfterFreshAOnTheSameAccount() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store), ui = RootUI()
        let controller = try ui.controller(coordinator)
        let old = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.complete(old, preparedAccount: f.config.selectedA)
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 42)
        guard let stale = action(controller, chat) else { return }
        try controller.lock()
        let fresh = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.complete(fresh, preparedAccount: f.config.selectedA)
        XCTAssertThrowsError(try controller.performChatVisibilityAction(stale))
        XCTAssertFalse(ui.covered); XCTAssertEqual(ui.root, f.config.selectedA)
        XCTAssertFalse(try controller.withActivePolicy { $0.isMarkedHidden(chat) })
        guard let current = action(controller, chat) else { return }
        _ = try controller.performChatVisibilityAction(current)
        XCTAssertTrue(ui.covered)
    }

    func testForeignVisibilityActionDoesNotDisturbANewerReadyRoot() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let firstUI = RootUI(), secondUI = RootUI()
        let first = try firstUI.controller(coordinator)
        let initial = try first.prepare(coordinator.beginUnlock(pin: "123456"))
        try first.complete(initial, preparedAccount: f.config.selectedA)
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 42)
        guard let foreign = action(first, chat) else { return }
        let second = try secondUI.controller(coordinator)
        let current = try second.prepare(coordinator.beginUnlock(pin: "123456"))
        try second.complete(current, preparedAccount: f.config.selectedA)
        XCTAssertThrowsError(try second.performChatVisibilityAction(foreign))
        XCTAssertFalse(secondUI.covered); XCTAssertEqual(secondUI.root, f.config.selectedA)
        XCTAssertFalse(try second.withActivePolicy { $0.isMarkedHidden(chat) })
    }

    func testVisibilityDescriptorDeniesBUnknownPeersAndInactiveRoot() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store), ui = RootUI()
        let controller = try ui.controller(coordinator)
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 42)
        let b = try controller.prepare(coordinator.beginUnlock(pin: "654321"))
        XCTAssertThrowsError(try controller.makeChatVisibilityAction(chat))
        try controller.complete(b, preparedAccount: f.config.selectedB)
        XCTAssertThrowsError(try controller.makeChatVisibilityAction(chat)); XCTAssertFalse(ui.covered)
        try controller.lock()
        let a = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.complete(a, preparedAccount: f.config.selectedA)
        XCTAssertThrowsError(try controller.makeChatVisibilityAction(ChatIdentity(account: f.config.selectedA, peerNamespace: 7, peerID: 42)))
        let unknown = AccountIdentity(installation: f.config.installation, environment: .production, recordID: 88, userID: 88)
        XCTAssertThrowsError(try controller.makeChatVisibilityAction(ChatIdentity(account: unknown, peerNamespace: 0, peerID: 42)))
        XCTAssertFalse(ui.covered)
        ui.active = false
        XCTAssertThrowsError(try controller.makeChatVisibilityAction(chat))
        XCTAssertTrue(ui.covered); XCTAssertNil(ui.root); XCTAssertEqual(coordinator.state, .locked)
    }

    func testShareProcessCannotObtainAVisibilityMenuAction() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store, process: .shareExtension), ui = RootUI()
        let controller = try ui.controller(coordinator)
        let a = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.complete(a, preparedAccount: f.config.selectedA)
        XCTAssertThrowsError(try controller.makeChatVisibilityAction(ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 42)))
        XCTAssertFalse(ui.covered); XCTAssertEqual(try controller.withActivePolicy { $0.mode }, .a)
    }

    func testInactiveVisibilityActionCannotCommitBeforeItsRootIsDenied() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store), ui = RootUI()
        let controller = try ui.controller(coordinator)
        let a = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.complete(a, preparedAccount: f.config.selectedA)
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 42)
        guard let menu = action(controller, chat) else { return }
        ui.active = false
        XCTAssertThrowsError(try controller.performChatVisibilityAction(menu))
        XCTAssertTrue(ui.covered); XCTAssertNil(ui.root); XCTAssertEqual(coordinator.state, .locked)
        let fresh = try f.store.authenticate(pin: "123456")
        XCTAssertFalse(try f.store.configuration(grant: fresh).hiddenChats.contains(chat))
    }

    func testReentrantNewRootDuringPINChangeCoverSurvivesOldPreparationFailure() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let old = try controller.prepare(coordinator.beginUnlock(pin: "654321"))
        try controller.complete(old, preparedAccount: f.config.selectedB)
        ui.cover = {
            ui.cover = nil
            do {
                let newer = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
                try controller.complete(newer, preparedAccount: f.config.selectedA)
            } catch { XCTFail("Fresh root failed: \(error)") }
        }
        XCTAssertThrowsError(try controller.preparePINChange())
        XCTAssertEqual(try controller.withActivePolicy { $0.mode }, .a)
        XCTAssertFalse(ui.covered)
        XCTAssertEqual(ui.root, f.config.selectedA)
    }

    func testInactivePINManagementDiscardsRootAndExtensionDenialPreservesOwnRoot() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let active = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.complete(active, preparedAccount: f.config.selectedA)
        ui.active = false
        XCTAssertThrowsError(try controller.preparePINChange())
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertEqual(coordinator.state, .locked)
        let otherCoordinator = AccessModeCoordinator(store: f.store, process: .shareExtension)
        let otherUI = RootUI()
        let other = try otherUI.controller(otherCoordinator)
        let external = try other.prepare(otherCoordinator.beginUnlock(pin: "654321"))
        try other.complete(external, preparedAccount: f.config.selectedB)
        XCTAssertThrowsError(try other.preparePINChange())
        XCTAssertFalse(otherUI.covered)
        XCTAssertEqual(try other.withActivePolicy { $0.mode }, .b)
    }
    func testPINManagementDetachesAndCoversRootBeforeQueuedOperation() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let token = try controller.prepare(coordinator.beginUnlock(pin: "654321"))
        try controller.complete(token, preparedAccount: f.config.selectedB)
        let request = try controller.preparePINChange()
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertFalse(controller.hasActiveRoot)
        XCTAssertThrowsError(try controller.withActivePolicy { $0.mode })
        XCTAssertEqual(Array(ui.events.suffix(2)), ["cover", "discard"])
        try coordinator.executePINChange(request) { grant in
            XCTAssertTrue(ui.covered)
            XCTAssertNil(ui.root)
            try f.store.changePIN(grant: grant, currentPIN: "654321", newPIN: "222222")
        }
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertFalse(controller.hasActiveRoot)
        XCTAssertEqual(coordinator.state, .locked)
    }
    func testUnimplementedRestrictedAdaptersCannotPublishBAndDiscardPreviousRoot() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        ui.authorize = { policy in if policy.mode == .b { throw AccessError.unavailable } }
        let controller = try ui.controller(coordinator)
        let a = try controller.prepare(coordinator.beginUnlock(pin: "123456"))
        try controller.complete(a, preparedAccount: f.config.selectedA)
        XCTAssertFalse(ui.covered)
        XCTAssertThrowsError(try controller.prepare(coordinator.beginUnlock(pin: "654321")))
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertThrowsError(try controller.withActivePolicy { $0.mode })
    }

    func testReadinessRevokedWhilePreparingCannotPublishOrUncover() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ui = RootUI()
        let controller = try ui.controller(coordinator)
        let token = try controller.prepare(coordinator.beginUnlock(pin: "654321"))
        ui.authorize = { _ in throw AccessError.unavailable }
        XCTAssertThrowsError(try controller.complete(token, preparedAccount: f.config.selectedB))
        XCTAssertFalse(ui.events.contains("ready"))
        XCTAssertTrue(ui.covered)
        XCTAssertNil(ui.root)
        XCTAssertEqual(coordinator.state, .locked)
    }

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
