import XCTest
@testable import AccessModeCore

final class PINChangeRequestTests: XCTestCase {
    func testTemporaryPINAuthorityCannotReadAccountConfigurationOrChangeChatVisibility() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ticket = try coordinator.beginUnlock(pin: "123456")
        try coordinator.completePreparation(ticket)
        let request = try coordinator.preparePINChange(ticket: ticket)
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 50)
        try coordinator.executePINChange(request) { grant in
            XCTAssertThrowsError(try f.store.configuration(grant: grant))
            XCTAssertThrowsError(try f.store.setHidden(chat, hidden: true, grant: grant, expectedRevision: 1))
        }
        let state = try f.store.file.read()
        XCTAssertEqual(state.configuration.revision, 1)
        XCTAssertFalse(state.configuration.hiddenChats.contains(chat))
    }
    func testPreparationRevokesBothLocalAndExtensionAuthorityAndCompletionRequiresFreshPIN() throws {
        let f = try VaultFixture()
        let main = AccessModeCoordinator(store: f.store)
        let old = try main.beginUnlock(pin: "123456")
        try main.completePreparation(old)
        let extensionStore = try f.reopen()
        let extensionCoordinator = AccessModeCoordinator(store: extensionStore, process: .shareExtension)
        let external = try extensionCoordinator.beginUnlock(pin: "654321")
        try extensionCoordinator.completePreparation(external)
        let request = try main.preparePINChange(ticket: old)
        XCTAssertEqual(main.state, .preparing(.a))
        XCTAssertThrowsError(try main.withPolicy(old) { $0.mode })
        XCTAssertThrowsError(try extensionCoordinator.withPolicy(external) { $0.mode })
        let presentation = AccessLockPresentation(legacyIsLockable: true, manuallyLocked: false,
            modeState: main.state, modeRootReady: false, coverHeld: true, applicationActive: true)
        XCTAssertTrue(presentation.shouldCover)
        XCTAssertFalse(presentation.shouldCreatePIN)
        try main.executePINChange(request) { grant in
            XCTAssertEqual(grant.mode, .a)
            _ = try f.store.beginOwnerPINChange(grant: grant, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { Data("sealed-test-plan".utf8) })
            XCTAssertTrue(try f.store.resumeOwnerPINChange { _ in })
        }
        XCTAssertEqual(main.state, .locked)
        XCTAssertThrowsError(try main.withPolicy(old) { $0.mode })
        let fresh = try main.beginUnlock(pin: "222222")
        XCTAssertEqual(main.state, .preparing(.a))
        try main.completePreparation(fresh)
        XCTAssertEqual(try main.withPolicy(fresh) { $0.mode }, .a)
    }

    func testQueuedCancelledOrConsumedRequestCannotRunOrDisturbNewerPreparation() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let old = try coordinator.beginUnlock(pin: "123456")
        try coordinator.completePreparation(old)
        let request = try coordinator.preparePINChange(ticket: old)
        try coordinator.lock()
        var called = false
        XCTAssertThrowsError(try coordinator.executePINChange(request) { _ in called = true })
        XCTAssertFalse(called)
        let current = try coordinator.beginUnlock(pin: "654321")
        try coordinator.completePreparation(current)
        XCTAssertThrowsError(try coordinator.executePINChange(request) { _ in called = true })
        XCTAssertFalse(called)
        XCTAssertEqual(coordinator.state, .active(.b))
        let valid = try coordinator.preparePINChange(ticket: current)
        try coordinator.executePINChange(valid) { grant in
            try f.store.changePIN(grant: grant, currentPIN: "654321", newPIN: "222222")
        }
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertThrowsError(try coordinator.executePINChange(valid) { _ in called = true })
        XCTAssertFalse(called)
    }

    func testFailureRevokesTemporaryAuthorityAndDoesNotLeavePreparingState() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ticket = try coordinator.beginUnlock(pin: "123456")
        try coordinator.completePreparation(ticket)
        let request = try coordinator.preparePINChange(ticket: ticket)
        var temporary: AuthenticatedModeGrant?
        XCTAssertThrowsError(try coordinator.executePINChange(request) { grant in
            temporary = grant
            throw AccessError.unavailable
        })
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertThrowsError(try f.store.configuration(grant: XCTUnwrap(temporary)))
        XCTAssertThrowsError(try f.store.validatePINChangeGrant(XCTUnwrap(temporary)))
        XCTAssertThrowsError(try coordinator.executePINChange(request) { _ in XCTFail("Consumed failed request") })
    }

    func testExtensionCannotPreparePINChangeAndStorageFailureLocksMainBeforeReturning() throws {
        let f = try VaultFixture()
        let extensionCoordinator = AccessModeCoordinator(store: f.store, process: .shareExtension)
        let external = try extensionCoordinator.beginUnlock(pin: "654321")
        try extensionCoordinator.completePreparation(external)
        XCTAssertThrowsError(try extensionCoordinator.preparePINChange(ticket: external))
        XCTAssertEqual(extensionCoordinator.state, .active(.b))
        let main = AccessModeCoordinator(store: f.store)
        let ticket = try main.beginUnlock(pin: "123456")
        try main.completePreparation(ticket)
        f.keys.denied = true
        XCTAssertThrowsError(try main.preparePINChange(ticket: ticket))
        XCTAssertEqual(main.state, .locked)
    }

    func testOldReentrantCompletionCannotLockNewerAuthenticatedGeneration() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let ticket = try coordinator.beginUnlock(pin: "654321")
        try coordinator.completePreparation(ticket)
        let request = try coordinator.preparePINChange(ticket: ticket)
        var newer: AccessTicket?
        XCTAssertThrowsError(try coordinator.executePINChange(request) { grant in
            try f.store.changePIN(grant: grant, currentPIN: "654321", newPIN: "222222")
            newer = try coordinator.beginUnlock(pin: "123456")
        })
        XCTAssertEqual(coordinator.state, .preparing(.a))
        try coordinator.completePreparation(XCTUnwrap(newer))
        XCTAssertEqual(coordinator.state, .active(.a))
    }
}
