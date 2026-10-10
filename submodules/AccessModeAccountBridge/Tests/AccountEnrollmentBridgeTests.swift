import XCTest
import Foundation
@testable import AccessModeCore
@testable import AccessModeAccountBridge
@testable import TelegramCore
import SwiftSignalKit

final class BridgeDeviceKey: AccessDeviceKeyProvider {
    var namespaces: Set<String> = []
    var loads = 0
    var failOnLoad: Int?
    var onLoad: (() -> Void)?
    func loadKey(allowCreation: Bool) throws -> Data {
        loads += 1
        if loads == failOnLoad { throw AccessError.unavailable }
        onLoad?()
        return Data(repeating: 0x52, count: 32)
    }
    func hasCommittedState(namespace: String) throws -> Bool { namespaces.contains(namespace) }
    func recordCommittedState(namespace: String) throws { namespaces.insert(namespace) }
}

final class BridgeFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dual-pin-account-bridge-tests-\(UUID())")
    let keys = BridgeDeviceKey()
    let store: AccessCredentialStore
    let manager: AccountManager<TelegramAccountManagerTypes>
    let config: AccessConfiguration
    init() throws {
        store = try AccessCredentialStore(directory: directory.appendingPathComponent("vault"), namespace: "test.account-bridge", keyProvider: keys, iterations: 600_000)
        let installation = UUID()
        let shared = AccountIdentity(installation: installation, environment: .production, recordID: 10, userID: 10)
        config = try AccessConfiguration(installation: installation, accounts: [.init(identity: shared, ownership: .shared)], selectedA: shared, selectedB: shared)
        _ = try store.initialize(configuration: config, pinA: "123456", pinB: "654321")
        let path = directory.appendingPathComponent("accounts-metadata").path
        guard !FileManager.default.fileExists(atPath: path) else { throw AccessError.invalidConfiguration }
        // Upstream creates missing atomic metadata only with this flag. This is
        // solely our verified-new temporary UUID fixture, never existing data.
        manager = AccountManager<TelegramAccountManagerTypes>(basePath: path, isTemporary: false, isReadOnly: false,
            useCaches: false, removeDatabaseOnError: true,
            accessChallenge: AccountManagerAccessChallenge(prepare: { _ in }, resolve: { _, _ in .some(.none) }, finishInitialization: {}))
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

final class FakeLogoutTransport: AccountEnrollmentLogoutTransport {
    let recordID: Int64
    let environment: AccessModeCore.AccountEnvironment
    var reply: Signal<AccountEnrollmentLogoutReply, NoError>
    var starts = 0
    var hasOriginalAuthorizationBinding = false
    var isOriginalSessionCurrent = true
    var revokedSessionKey: AccountEnrollmentSessionKey? = try? AccountEnrollmentSessionKey(datacenterID: 2, digest: Data(repeating: 0x61, count: 32))
    var onStart: (() -> Void)?
    init(recordID: Int64, environment: AccessModeCore.AccountEnvironment, reply: Signal<AccountEnrollmentLogoutReply, NoError>) {
        self.recordID = recordID; self.environment = environment; self.reply = reply
    }
    func logout() -> Signal<AccountEnrollmentLogoutReply, NoError> {
        return Signal { subscriber in
            self.starts += 1
            self.onStart?()
            return self.reply.start(next: { subscriber.putNext($0) }, completed: { subscriber.putCompletion() })
        }
    }
}

final class AccountEnrollmentBridgeTests: XCTestCase {
    func testMissingOriginalSessionRefusesRPCAndKeepsCleanupEvenForLoggedOutReply() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store), a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        let transport = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: .single(.loggedOut))
        transport.isOriginalSessionCurrent = false
        logoutUnavailable(try value(AccountEnrollmentBridge.revokeSession(transport: transport, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)))
        XCTAssertEqual(transport.starts, 0)
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }

    func testKeyReplacementWhileLogoutIsInFlightCannotMintARevocationProof() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store), a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        _ = try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup))
        let transport = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: .single(.loggedOut))
        transport.onStart = { transport.isOriginalSessionCurrent = false }
        logoutUnavailable(try value(AccountEnrollmentBridge.revokeSession(transport: transport, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)))
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }

    func testRecordEnvironmentChangingBeforeLogoutResultCannotMintAProof() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store), a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        _ = try value(f.manager.transaction { transaction -> Void in
            XCTAssertTrue(switchAuthorizationRecord(transaction: transaction, id: id, testingEnvironment: false, isSupportUser: false))
        })
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        let changed = f.manager.transaction { transaction -> AccountEnrollmentLogoutReply in
            transaction.updateRecord(id, { _ in AccountRecord(id: id,
                attributes: [.environment(AccountEnvironmentAttribute(environment: .test))], temporarySessionId: nil) })
            return .loggedOut
        }
        let transport = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: changed)
        logoutUnavailable(try value(AccountEnrollmentBridge.revokeSession(transport: transport, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)))
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }

    func testInactiveSessionReplyNeedsAnOriginalCredentialBinding() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, permit) = creation else { XCTFail("Current creation refused"); return }
        try bindFakeSessionKey(coordinator, permit, a)
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        let unbound = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: .single(.rpcError(code: 401, type: "AUTH_KEY_UNREGISTERED")))
        logoutUnavailable(try value(AccountEnrollmentBridge.revokeSession(transport: unbound, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)))
        // Tests simulate a future verified transport; public Native has no override.
        let bound = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: .single(.rpcError(code: 401, type: "SESSION_REVOKED")))
        bound.hasOriginalAuthorizationBinding = true
        guard case .confirmed = try value(AccountEnrollmentBridge.revokeSession(transport: bound, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)) else {
            XCTFail("Bound inactive response was refused"); return
        }
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }

    func testPublicLogoutAdapterRefusesAnUpgradingAccountWithoutNetwork() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        try coordinator.bindEnrollment(permit, provisionalRecordID: 20, ticket: a)
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        logoutUnavailable(try value(AccountEnrollmentBridge.revokeProvisionalSession(account: .upgrading(0), accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)))
        XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, 20)
    }
    func testOnlyExactConfirmedLogoutOrInactiveAuthorizationResponsesAreAccepted() {
        XCTAssertTrue(AccountEnrollmentBridge.isConfirmedSessionLogout(.loggedOut))
        for type in ["AUTH_KEY_UNREGISTERED", "AUTH_KEY_INVALID", "SESSION_REVOKED", "SESSION_EXPIRED"] {
            XCTAssertTrue(AccountEnrollmentBridge.isConfirmedSessionLogout(.rpcError(code: 401, type: type)))
            XCTAssertFalse(AccountEnrollmentBridge.isConfirmedSessionLogout(.rpcError(code: 400, type: type)))
            XCTAssertFalse(AccountEnrollmentBridge.isConfirmedSessionLogout(.rpcError(code: 401, type: type + "_OTHER")))
        }
        XCTAssertTrue(AccountEnrollmentBridge.isConfirmedSessionLogout(.rpcError(code: 406, type: "AUTH_KEY_DUPLICATED")))
        for type in ["AUTH_KEY_PERM_EMPTY", "SESSION_PASSWORD_NEEDED", "USER_DEACTIVATED", "UNKNOWN"] {
            XCTAssertFalse(AccountEnrollmentBridge.isConfirmedSessionLogout(.rpcError(code: 401, type: type)))
        }
        XCTAssertFalse(AccountEnrollmentBridge.isConfirmedSessionLogout(.rpcError(code: 420, type: "FLOOD_WAIT_30")))
        XCTAssertFalse(AccountEnrollmentBridge.isConfirmedSessionLogout(.rpcError(code: 500, type: "INTERNAL")))
        XCTAssertFalse(AccountEnrollmentBridge.isConfirmedSessionLogout(.unavailable))
    }

    func testScopedConfirmedSessionLogoutKeepsMetadataAndLedgerForLaterCleanup() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .test))
        guard case let .created(id, permit) = creation else { XCTFail("Current creation refused"); return }
        try bindFakeSessionKey(coordinator, permit, a)
        XCTAssertTrue(try value(f.manager.transaction { switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: true, isSupportUser: false) }))
        try coordinator.lock()
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        let transport = FakeLogoutTransport(recordID: id.int64, environment: .test, reply: .single(.loggedOut))
        let result = try value(AccountEnrollmentBridge.revokeSession(transport: transport, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup))
        guard case .confirmed = result else { XCTFail("Scoped logout was not confirmed"); return }
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(try value(f.manager.transaction { $0.getRecords().map { $0.id } }), [id])
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
        XCTAssertEqual(coordinator.state, .locked)
        // Fake transport proves adapter control flow, not an actual server logout.
    }

    func testLogoutCannotStartBeforeOwnedAuthDetachmentOrWithTheWrongTarget() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        let stillAttached = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: .single(.loggedOut))
        logoutUnavailable(try value(AccountEnrollmentBridge.revokeSession(transport: stillAttached, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)))
        XCTAssertEqual(stillAttached.starts, 0)
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        for transport in [FakeLogoutTransport(recordID: id.int64 ^ 1, environment: .production, reply: .single(.loggedOut)),
                          FakeLogoutTransport(recordID: id.int64, environment: .test, reply: .single(.loggedOut))] {
            logoutUnavailable(try value(AccountEnrollmentBridge.revokeSession(transport: transport, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)))
            XCTAssertEqual(transport.starts, 0)
        }
        let other = try BridgeFixture(), foreign = AccessModeCoordinator(store: other.store)
        let share = AccessModeCoordinator(store: f.store, process: .shareExtension)
        for denied in [foreign, share] {
            let transport = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: .single(.loggedOut))
            logoutUnavailable(try value(AccountEnrollmentBridge.revokeSession(transport: transport, accountManager: f.manager, coordinator: denied, cleanup: cleanup)))
            XCTAssertEqual(transport.starts, 0)
        }
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }

    func testLogoutEmptyFailureAndTimeoutDoNotConfirmOrAcknowledgeCleanup() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        let replies: [Signal<AccountEnrollmentLogoutReply, NoError>] = [.single(.unavailable), .complete(), .never()]
        for reply in replies {
            let transport = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: reply)
            logoutUnavailable(try value(AccountEnrollmentBridge.revokeSession(transport: transport, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup, timeoutSeconds: 0.02)))
            XCTAssertEqual(transport.starts, 1)
            XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
        }
        XCTAssertEqual(try coordinator.withPolicy(a) { $0.mode }, .a)
    }

    /// A confirmation needs a bound key to persist its receipt against.
    private func bindFakeSessionKey(_ coordinator: AccessModeCoordinator, _ permit: AccountEnrollmentPermit, _ ticket: AccessTicket) throws {
        let key = try XCTUnwrap(FakeLogoutTransport(recordID: 0, environment: .production, reply: .complete()).revokedSessionKey)
        try coordinator.bindEnrollmentSessionKey(permit, sessionKey: key, ticket: ticket)
    }

    private func logoutUnavailable(_ result: AccountEnrollmentLogoutResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unavailable = result else { XCTFail("Unconfirmed logout produced proof", file: file, line: line); return }
    }

    func testConfirmationNeedsAKeyItCanRecordAReceiptFor() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, permit) = creation else { XCTFail("Current creation refused"); return }
        try bindFakeSessionKey(coordinator, permit, a)
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        // No key never reaches the server; an unbound key's reply is not a proof.
        let keyless = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: .single(.loggedOut))
        keyless.revokedSessionKey = nil
        logoutUnavailable(try value(AccountEnrollmentBridge.revokeSession(transport: keyless, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)))
        XCTAssertEqual(keyless.starts, 0)
        let unbound = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: .single(.loggedOut))
        unbound.revokedSessionKey = try AccountEnrollmentSessionKey(datacenterID: 4, digest: Data(repeating: 0x62, count: 32))
        logoutUnavailable(try value(AccountEnrollmentBridge.revokeSession(transport: unbound, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)))
        XCTAssertEqual(unbound.starts, 1)
        XCTAssertEqual(try coordinator.confirmedEnrollmentSessionKeys(cleanup), [])
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }

    func testRetainedLogoutSignalCannotIssueAnotherRPC() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, permit) = creation else { XCTFail("Current creation refused"); return }
        try bindFakeSessionKey(coordinator, permit, a)
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        let transport = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: .single(.loggedOut))
        let signal = AccountEnrollmentBridge.revokeSession(transport: transport, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)
        guard case .confirmed = try value(signal) else { XCTFail("Current logout refused"); return }
        logoutUnavailable(try value(signal))
        XCTAssertEqual(transport.starts, 1)
    }

    func testLateLogoutReplyCannotConfirmOrResetANewerOwner() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        let old = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: old)), .detached)
        let pipe = ValuePipe<AccountEnrollmentLogoutReply>(), began = expectation(description: "Scoped fake RPC began")
        let done = expectation(description: "Stale reply refused")
        let transport = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: pipe.signal())
        transport.onStart = { began.fulfill() }
        let pending = AccountEnrollmentBridge.revokeSession(transport: transport, accountManager: f.manager, coordinator: coordinator, cleanup: old).start(next: {
            self.logoutUnavailable($0); done.fulfill()
        })
        defer { pending.dispose() }
        wait(for: [began], timeout: 3)
        // A different fixture worker resolved this no-session owner first.
        try coordinator.acknowledgeEnrollmentCleanup(old)
        let next = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .test))
        guard case let .created(newID, _) = next else { XCTFail("Next creation refused"); return }
        let current = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        pipe.putNext(.loggedOut)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), newID)
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, current.provisionalRecordID)
        XCTAssertEqual(try coordinator.withPolicy(a) { $0.mode }, .a)
    }

    func testDisposedQueuedLogoutCannotStartItsRPC() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        let began = expectation(description: "Earlier metadata transaction began"), release = DispatchSemaphore(value: 0)
        let blocker = f.manager.transaction { _ -> Void in
            began.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }.start()
        defer { release.signal(); blocker.dispose() }
        wait(for: [began], timeout: 3)
        let transport = FakeLogoutTransport(recordID: id.int64, environment: .production, reply: .single(.loggedOut))
        let pending = AccountEnrollmentBridge.revokeSession(transport: transport, accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)
            .start(next: { _ in XCTFail("Disposed queued logout delivered a result") })
        pending.dispose(); release.signal()
        XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertEqual(transport.starts, 0)
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }
    func testSubmittedAuthDetachmentDrainsAfterItsObserverIsDisposed() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        let began = expectation(description: "Earlier metadata transaction began")
        let release = DispatchSemaphore(value: 0)
        let blocker = f.manager.transaction { _ -> Void in
            began.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }.start()
        defer { release.signal(); blocker.dispose() }
        wait(for: [began], timeout: 3)
        let submitted = AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)
            .start(next: { _ in XCTFail("Disposed cleanup observer delivered a result") })
        submitted.dispose()
        release.signal()
        XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }

    func testUnreadableCleanupOwnershipCannotDetachAnyAuthAndCanBeRetried() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        f.keys.failOnLoad = f.keys.loads + 1
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .unavailable)
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), id)
        f.keys.failOnLoad = nil
        XCTAssertEqual(try coordinator.withPolicy(a) { $0.mode }, .a)
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }

    func testOwnedAuthDetachmentWhileLockedStopsLatePromotionAndKeepsCleanupPending() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        try coordinator.lock()
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertFalse(try value(f.manager.transaction { switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: false, isSupportUser: false) }))
        XCTAssertTrue(try value(f.manager.transaction { $0.getRecords().isEmpty }))
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
        XCTAssertEqual(coordinator.state, .locked)
        // No acknowledgment: detaching auth is not server/session cleanup proof.
    }

    func testOwnedAuthDetachmentCannotRemoveAReplacementAuth() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        let replacement = try XCTUnwrap(value(f.manager.transaction { $0.createAuth([.environment(AccountEnvironmentAttribute(environment: .test))])?.id }))
        XCTAssertNotEqual(replacement, id)
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), replacement)
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }

    func testAuthDetachmentLeavesAnAlreadyPromotedOwnedRecordForSessionCleanup() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        XCTAssertTrue(try value(f.manager.transaction { switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: false, isSupportUser: false) }))
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .detached)
        XCTAssertEqual(try value(f.manager.transaction { $0.getRecords().map { $0.id } }), [id])
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrent()?.0 }), id)
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
        XCTAssertEqual(try coordinator.withPolicy(a) { $0.visibleAccounts }, [f.config.selectedA])
        // No deletion/acknowledgment without actual session cleanup proof.
    }

    func testCleanupEnvironmentMismatchPreservesTheMatchingRawAuth() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: a)
        let id = try XCTUnwrap(value(f.manager.transaction { $0.createAuth([.environment(AccountEnvironmentAttribute(environment: .production))])?.id }))
        // Deliberately inconsistent fixtures simulate changed raw metadata.
        try coordinator.bindEnrollment(permit, provisionalRecordID: id.int64, environment: .test, ticket: a)
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: cleanup)), .unavailable)
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), id)
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.environment, .test)
    }

    func testStaleAuthDetachmentCannotTouchANewerProvisionalOwner() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let first = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = first else { XCTFail("Current creation refused"); return }
        let old = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        _ = try value(f.manager.transaction { transaction -> Void in
            XCTAssertEqual(transaction.getCurrentAuth()?.id, id)
            transaction.removeAuth()
        })
        XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
        try coordinator.acknowledgeEnrollmentCleanup(old)
        let next = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .test))
        guard case let .created(newID, _) = next else { XCTFail("Next creation refused"); return }
        let current = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: old)), .unavailable)
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), newID)
        XCTAssertEqual(current.provisionalRecordID, newID.int64)
        XCTAssertEqual(try coordinator.withPolicy(a) { $0.mode }, .a)
    }

    func testForeignAndShareAuthDetachmentCannotMutateMainMetadata() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("Current creation refused"); return }
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        let other = try BridgeFixture(), foreign = AccessModeCoordinator(store: other.store)
        let share = AccessModeCoordinator(store: f.store, process: .shareExtension)
        for denied in [foreign, share] {
            XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: denied, cleanup: cleanup)), .unavailable)
            XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), id)
        }
    }

    func testDisposedCreationDoesNotRunAfterAnEarlierMetadataTransaction() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let began = expectation(description: "Earlier metadata transaction began")
        let release = DispatchSemaphore(value: 0)
        let blocker = f.manager.transaction { _ -> Void in
            began.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }.start()
        defer { release.signal(); blocker.dispose() }
        wait(for: [began], timeout: 3)
        let creation = AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production)
            .start(next: { _ in XCTFail("Disposed creation delivered a result") })
        creation.dispose()
        release.signal()
        XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertNil(try coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try coordinator.withPolicy(a) { $0.mode }, .a)
    }

    func testDisposalDuringBindingRollsBackMetadataAndRetainsExactCleanupOwnership() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let binding = expectation(description: "Durable binding began")
        let release = DispatchSemaphore(value: 0)
        var exposed = false
        let observer = f.manager.accountRecords().start(next: { if $0.currentAuthAccount != nil { exposed = true } })
        defer { release.signal(); observer.dispose(); f.keys.onLoad = nil }
        f.keys.loads = 0
        f.keys.onLoad = {
            if f.keys.loads == 2 {
                binding.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            }
        }
        let creation = AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production)
            .start(next: { _ in XCTFail("Disposed creation delivered a result") })
        wait(for: [binding], timeout: 3)
        creation.dispose()
        release.signal()
        let remaining = try value(f.manager.transaction { $0.getCurrentAuth() })
        XCTAssertNil(remaining)
        XCTAssertFalse(exposed)
        f.keys.onLoad = nil
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(cleanup.environment, .production)
        // This fixture has no session and the metadata queue confirmed absence.
        guard remaining == nil else { return }
        try coordinator.acknowledgeEnrollmentCleanup(cleanup)
        XCTAssertNil(try coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try coordinator.withPolicy(a) { $0.mode }, .a)
    }

    func testRetainedCreationSignalCannotCreateAgainAfterItsFirstOwnerWasCleaned() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let signal = AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production)
        let first = try value(signal)
        guard case let .created(id, _) = first else { XCTFail("Current creation refused"); return }
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(cleanup.provisionalRecordID, id.int64)
        _ = try value(f.manager.transaction { transaction -> Void in
            XCTAssertEqual(transaction.getCurrentAuth()?.id, id)
            transaction.removeAuth()
        })
        try coordinator.acknowledgeEnrollmentCleanup(cleanup)
        unavailable(try value(signal))
        XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertNil(try coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try coordinator.withPolicy(a) { $0.mode }, .a)
    }
    func testBindingFailureRollsBackOnlyItsUnpublishedAuthRecord() throws {
        for failure in [1, 2] {
            let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
            let a = try ready(coordinator)
            var exposed = false
            let observer = f.manager.accountRecords().start(next: { if $0.currentAuthAccount != nil { exposed = true } })
            defer { observer.dispose() }
            f.keys.loads = 0; f.keys.failOnLoad = failure
            unavailable(try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production)))
            // A transaction on the same metadata queue also drains publication.
            XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
            XCTAssertFalse(exposed)
            // The rolled-back reservation leaves no directory for a later owner.
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).filter { $0.hasPrefix("account-") }, [])
            XCTAssertEqual(coordinator.state, .locked)
            f.keys.failOnLoad = nil
            XCTAssertNil(try coordinator.claimEnrollmentCleanup())
            XCTAssertEqual(try coordinator.withPolicy(ready(coordinator)) { $0.visibleAccounts }, [f.config.selectedA])
        }
    }

    func testThePublishedBindingAndMetadataSurviveIndependentReaders() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let result = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production))
        guard case let .created(id, _) = result else { XCTFail("Current creation refused"); return }
        let reader = AccountManager<TelegramAccountManagerTypes>(basePath: f.manager.basePath, isTemporary: false, isReadOnly: true,
            useCaches: false, removeDatabaseOnError: false,
            accessChallenge: AccountManagerAccessChallenge(prepare: { _ in }, resolve: { _, _ in nil }, finishInitialization: {}))
        XCTAssertEqual(try value(reader.transaction { $0.getCurrentAuth()?.id }), id)
        let reopenedStore = try AccessCredentialStore(directory: f.directory.appendingPathComponent("vault"), namespace: "test.account-bridge", keyProvider: f.keys, iterations: 600_000)
        let reopened = AccessModeCoordinator(store: reopenedStore)
        let cleanup = try XCTUnwrap(reopened.claimEnrollmentCleanup())
        XCTAssertEqual(cleanup.provisionalRecordID, id.int64); XCTAssertEqual(cleanup.environment, .production)
        XCTAssertEqual(reopened.state, .locked)
        // Keep cleanup pending: no server/session or raw-record deletion occurred.
    }
    private func value<T>(_ signal: Signal<T, NoError>, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let done = expectation(description: "Metadata result")
        var result: T?
        let disposable = signal.start(next: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        disposable.dispose()
        return try XCTUnwrap(result, file: file, line: line)
    }
    private func ready(_ coordinator: AccessModeCoordinator, pin: String = "123456") throws -> AccessTicket {
        let ticket = try coordinator.beginUnlock(pin: pin)
        try coordinator.completePreparation(ticket)
        return ticket
    }
    private func unavailable(_ result: AccountEnrollmentCreation, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unavailable = result else { XCTFail("Denied creation returned a record", file: file, line: line); return }
    }

    func testCreationPublishesOnlyAfterExactEnvironmentBindingAndKeepsItsCleanupAcrossLock() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        let published = expectation(description: "Owned metadata published")
        var ownedBeforePublication = false
        let observer = (f.manager.accountRecords() |> filter { $0.currentAuthAccount != nil } |> take(1)).start(next: { view in
            guard let id = view.currentAuthAccount?.id else { return }
            do {
                let state = try f.store.file.read()
                ownedBeforePublication = state.pendingEnrollmentCleanup?.provisionalRecordID == id.int64 &&
                    state.pendingEnrollmentCleanup?.environment == .test && state.pendingEnrollment?.provisionalRecordID == id.int64
            } catch { XCTFail("Ownership unavailable at publication: \(error)") }
            published.fulfill()
        })
        defer { observer.dispose() }
        let result = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .test))
        guard case let .created(id, permit) = result else { XCTFail("Current creation refused"); return }
        wait(for: [published], timeout: 5)
        XCTAssertTrue(ownedBeforePublication)
        let auth = try value(f.manager.transaction { $0.getCurrentAuth() })
        XCTAssertEqual(auth?.id, id)
        XCTAssertTrue(auth?.attributes.contains { if case let .environment(e) = $0 { return e.environment == .test }; return false } == true)
        XCTAssertNoThrow(try coordinator.bindEnrollment(permit, provisionalRecordID: id.int64, environment: .test, ticket: a))
        try coordinator.lock()
        let cleanup = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(cleanup.provisionalRecordID, id.int64); XCTAssertEqual(cleanup.environment, .test)
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), id)
        // No acknowledgment: actual auth metadata still exists.
    }

    func testCreationRefusesAnAllocatedIDWhoseAccountDirectoryAlreadyExists() throws {
        // A directory without an AccountManager record (an orphan) keeps its
        // Postbox and keys; adopting it would make old data the "new" session.
        for kind in ["directory", "symlink", "dangling"] {
            let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
            let a = try ready(coordinator)
            let outside = f.directory.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: outside.appendingPathComponent("db"))
            var planted: URL?
            let result = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator,
                ticket: a, environment: .production, beforeDirectoryReservation: { id in
                    let path = f.directory.appendingPathComponent(accountRecordIdPathName(id))
                    switch kind {
                    case "directory":
                        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                        try? Data([4, 5, 6]).write(to: path.appendingPathComponent("db"))
                    case "symlink":
                        try? FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
                    default:
                        try? FileManager.default.createSymbolicLink(at: path, withDestinationURL: f.directory.appendingPathComponent("missing"))
                    }
                    planted = path
                }))
            unavailable(result)
            let path = try XCTUnwrap(planted)
            XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: path.path), kind)
            if kind == "directory" { XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("db")), Data([4, 5, 6])) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["db"], kind)
            XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("db")), Data([1, 2, 3]), kind)
            XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }), kind)
            XCTAssertNil(try coordinator.claimEnrollmentCleanup(), kind)
            XCTAssertEqual(try coordinator.withPolicy(a) { $0.selectedAccount }, f.config.selectedA, kind)
            // The refusal is not sticky: a later attempt allocates another ID.
            guard case let .created(id, _) = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager,
                coordinator: coordinator, ticket: a, environment: .production)) else { XCTFail("Retry refused: \(kind)"); continue }
            XCTAssertNotEqual(f.directory.appendingPathComponent(accountRecordIdPathName(id)), path, kind)
        }
    }

    func testCreationReservesOnlyItsOwnEmptyAccountDirectory() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let a = try ready(coordinator)
        guard case let .created(id, _) = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager,
            coordinator: coordinator, ticket: a, environment: .production)) else { XCTFail("Current creation refused"); return }
        let path = f.directory.appendingPathComponent(accountRecordIdPathName(id)).path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).filter { $0.hasPrefix("account-") },
            [accountRecordIdPathName(id)])
    }

    func testAnExistingAuthFlowCannotBeReplacedOrClaimedByAnotherCreation() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let existing = try XCTUnwrap(value(f.manager.transaction { $0.createAuth([])?.id }))
        let a = try ready(coordinator)
        unavailable(try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: a, environment: .production)))
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), existing)
        XCTAssertNil(try coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try coordinator.withPolicy(a) { $0.selectedAccount }, f.config.selectedA)
    }

    func testAStaleCreationCannotResetANewerRoleOrCreateAuthMetadata() throws {
        let f = try BridgeFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let old = try ready(coordinator), b = try ready(coordinator, pin: "654321")
        unavailable(try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: old, environment: .production)))
        XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertNil(try coordinator.claimEnrollmentCleanup())
        XCTAssertEqual(try coordinator.withPolicy(b) { $0.mode }, .b)
    }

    func testShareCannotCreateAProvisionalRecordWithItsAuthenticatedTicket() throws {
        let f = try BridgeFixture(), share = AccessModeCoordinator(store: f.store, process: .shareExtension)
        let a = try ready(share)
        unavailable(try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: share, ticket: a, environment: .production)))
        XCTAssertNil(try value(f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertEqual(try share.withPolicy(a) { $0.mode }, .a)
    }
}
