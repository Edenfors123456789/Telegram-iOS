import Foundation
import XCTest
import AccessModeCore
@testable import AccessModeAccountBridge
@testable import TelegramCore
import MtProtoKit
import SwiftSignalKit

private final class LogoutKeySource: AccountEnrollmentSessionKeySource {
    var recordID: Int64
    var environment: AccessModeCore.AccountEnvironment = .production
    var basePath: String
    var main: AccountEnrollmentSessionKey?
    var additional: [Int32: AccountEnrollmentSessionKey] = [:]
    var onRead: (() -> Void)?
    init(f: BridgeFixture, id: AccountRecordId, key: AccountEnrollmentSessionKey) {
        recordID = id.int64; basePath = f.directory.appendingPathComponent(accountRecordIdPathName(id)).path; main = key
    }
    func persistentFingerprint() -> AccountEnrollmentSessionKey? { onRead?(); return main }
    func persistentFingerprint(datacenterID: Int32) -> AccountEnrollmentSessionKey? {
        if let main, main.datacenterID == datacenterID { return main }
        return additional[datacenterID]
    }
}

private struct OwnedLogoutFixture {
    let f: BridgeFixture
    let coordinator: AccessModeCoordinator
    let ticket: AccessTicket
    let id: AccountRecordId
    let owner: AccountEnrollmentCleanupTicket
    let source: LogoutKeySource
}

final class NativeEnrollmentLogoutTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let done = expectation(description: "native logout result"), result = Atomic<T?>(value: nil)
        let disposable = signal.start(next: { _ = result.swap($0); done.fulfill() })
        wait(for: [done], timeout: 5); disposable.dispose()
        return try XCTUnwrap(result.with { $0 })
    }
    private func key(_ dc: Int32 = 1, _ byte: UInt8 = 0x51) throws -> AccountEnrollmentSessionKey {
        try AccountEnrollmentSessionKey(datacenterID: dc, digest: Data(repeating: byte, count: 32))
    }
    private func owned(bind: Bool = true, extra: AccountEnrollmentSessionKey? = nil) throws -> OwnedLogoutFixture {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store)
        let t = try c.beginUnlock(pin: "123456"); try c.completePreparation(t)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: c, ticket: t, environment: .production))
        guard case let .created(id, permit) = creation else { throw AccessError.unavailable }
        let first = try key(), source = LogoutKeySource(f: f, id: id, key: first)
        if bind { try c.bindEnrollmentSessionKey(permit, sessionKey: first, ticket: t) }
        if let extra { try c.bindEnrollmentSessionKey(permit, sessionKey: extra, ticket: t) }
        let owner = try XCTUnwrap(c.claimEnrollmentCleanup())
        _ = try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: c, cleanup: owner))
        return OwnedLogoutFixture(f: f, coordinator: c, ticket: t, id: id, owner: owner, source: source)
    }
    private func transport(_ o: OwnedLogoutFixture, coordinator: AccessModeCoordinator? = nil,
        engine: @escaping () -> NetworkEngineKind = { .mtProtoKit }, stop: @escaping () -> Void = {},
        rpc: @escaping (NetworkRequestAuthKeyScope) -> Signal<Void, MTRpcError> = { _ in .single(()) }) -> ScopedEnrollmentLogoutTransport {
        ScopedEnrollmentLogoutTransport(source: o.source, accountManager: o.f.manager, coordinator: coordinator ?? o.coordinator,
            cleanup: o.owner, engineKind: engine, stopServiceTasks: stop, request: rpc)
    }
    private func unavailable(_ result: AccountEnrollmentLogoutResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unavailable = result else { XCTFail("unexpected revocation proof", file: file, line: line); return }
    }
    private func replyUnavailable(_ result: AccountEnrollmentLogoutReply, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unavailable = result else { XCTFail("unexpected native success", file: file, line: line); return }
    }

    func testCapturedScopeIsLazyExactAndTheTransportCannotReplay() throws {
        let o = try owned(); var starts = 0, stops = 0, scope: NetworkRequestAuthKeyScope?
        let adapter = transport(o, stop: { stops += 1 }, rpc: { current in starts += 1; scope = current; return .single(()) })
        XCTAssertTrue(adapter.isOriginalSessionCurrent)
        let signal = adapter.logout()
        XCTAssertEqual(starts, 0); XCTAssertEqual(stops, 0)
        let first = try value(signal)
        if case .loggedOut = first {} else { XCTFail("original scoped reply denied") }
        XCTAssertEqual(scope?.datacenterId, 1); XCTAssertEqual(scope?.permanentKeyDigest, o.source.main?.digest)
        replyUnavailable(try value(signal)); replyUnavailable(try value(adapter.logout()))
        XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 1)
        XCTAssertFalse(adapter.hasOriginalAuthorizationBinding, "temporary-key errors cannot prove permanent logout")
        XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
    }

    func testScopedSuccessMintsOnlyAnEphemeralProofAndKeepsTheLedger() throws {
        let o = try owned(); var starts = 0
        let adapter = transport(o, rpc: { _ in starts += 1; return .single(()) })
        let result = try value(AccountEnrollmentBridge.revokeSession(transport: adapter, accountManager: o.f.manager, coordinator: o.coordinator, cleanup: o.owner))
        guard case .confirmed = result else { XCTFail("valid scoped fake reply denied"); return }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
        XCTAssertEqual(try o.coordinator.boundEnrollmentSessionKeys(o.owner), [try key()])
        XCTAssertEqual(try o.coordinator.confirmedEnrollmentSessionKeys(o.owner), [try key()])
    }

    func testScopedSuccessRecordsOnlyTheRevokedOriginalKey() throws {
        // One scoped auth.LoggedOut proves nothing about another datacenter's key.
        let second = try key(2, 0x52), o = try owned(extra: second)
        o.source.additional[2] = second
        let adapter = transport(o)
        guard case .confirmed = try value(AccountEnrollmentBridge.revokeSession(transport: adapter, accountManager: o.f.manager,
            coordinator: o.coordinator, cleanup: o.owner)) else { XCTFail("valid scoped fake reply denied"); return }
        XCTAssertEqual(try o.coordinator.confirmedEnrollmentSessionKeys(o.owner), [try key()])
        XCTAssertEqual(try o.coordinator.boundEnrollmentSessionKeys(o.owner), [try key(), second])
    }

    func testConfirmationRequiresItsDurableReceipt() throws {
        // Fail each later vault key load in turn: whichever step fails, a
        // confirmation is returned exactly when its receipt was persisted.
        var refusedAfterReply = false
        for offset in 1 ... 6 {
            let o = try owned(); var starts = 0
            let adapter = transport(o, rpc: { _ in
                starts += 1
                o.f.keys.failOnLoad = o.f.keys.loads + offset
                return .single(())
            })
            let result = try value(AccountEnrollmentBridge.revokeSession(transport: adapter, accountManager: o.f.manager,
                coordinator: o.coordinator, cleanup: o.owner))
            o.f.keys.failOnLoad = nil
            XCTAssertEqual(starts, 1)
            let receipts = try o.coordinator.confirmedEnrollmentSessionKeys(o.owner)
            switch result {
            case .confirmed: XCTAssertEqual(receipts, [try key()], "offset \(offset)")
            case .unavailable:
                refusedAfterReply = true
                XCTAssertEqual(receipts, [], "offset \(offset)")
            }
            XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
        }
        XCTAssertTrue(refusedAfterReply, "no failed post-reply vault access was exercised")
    }

    func testAllSavedDatacentersAreRequiredAndAChangedMainNeedsANewAdapter() throws {
        let second = try key(2, 0x52), o = try owned(extra: second)
        var starts = 0, datacenter: Int32?
        let old = transport(o, rpc: { scope in starts += 1; datacenter = scope.datacenterId; return .single(()) })
        XCTAssertFalse(old.isOriginalSessionCurrent, "missing secondary original key")
        o.source.additional[2] = second
        XCTAssertTrue(old.isOriginalSessionCurrent)
        let oldSignal = old.logout()
        o.source.additional[1] = o.source.main; o.source.main = second
        XCTAssertFalse(old.isOriginalSessionCurrent, "do not silently rebase a retained request")
        replyUnavailable(try value(oldSignal)); XCTAssertEqual(starts, 0)
        let current = transport(o, rpc: { scope in starts += 1; datacenter = scope.datacenterId; return .single(()) })
        XCTAssertTrue(current.isOriginalSessionCurrent)
        if case .loggedOut = try value(current.logout()) {} else { XCTFail("current saved main refused") }
        XCTAssertEqual(starts, 1); XCTAssertEqual(datacenter, 2)
    }

    func testMissingForeignEnvironmentShareAndUnsupportedSourcesDenyBeforeSideEffects() throws {
        for variant in 0 ... 4 {
            let o = try owned(bind: variant != 0); var starts = 0, stops = 0
            if variant == 1 { o.source.basePath += "/foreign" }
            if variant == 2 { o.source.environment = .test }
            let c = variant == 3 ? AccessModeCoordinator(store: o.f.store, process: .shareExtension) : o.coordinator
            let adapter = transport(o, coordinator: c, engine: { variant == 4 ? .rust : .mtProtoKit },
                stop: { stops += 1 }, rpc: { _ in starts += 1; return .single(()) })
            XCTAssertFalse(adapter.isOriginalSessionCurrent)
            replyUnavailable(try value(adapter.logout()))
            XCTAssertEqual(starts, 0); XCTAssertEqual(stops, 0)
            XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
        }
    }

    func testStoppingTasksCannotReplaceTheKeyEngineOrOwnerAndThenSubmit() throws {
        for variant in 0 ... 2 {
            let o = try owned(); var starts = 0, stops = 0, engine: NetworkEngineKind = .mtProtoKit
            let replacement = try key(1, 0x53)
            let adapter = transport(o, engine: { engine }, stop: {
                stops += 1
                switch variant {
                case 0: o.source.main = replacement
                case 1: engine = .rust
                default:
                    // Component fixture only; no native session was revoked.
                    do { try o.coordinator.acknowledgeEnrollmentCleanup(o.owner) }
                    catch { XCTFail("fixture ownership removal refused: \(error)") }
                }
            }, rpc: { _ in starts += 1; return .single(()) })
            XCTAssertTrue(adapter.isOriginalSessionCurrent)
            replyUnavailable(try value(adapter.logout()))
            XCTAssertEqual(starts, 0); XCTAssertEqual(stops, 1)
        }
    }

    func testEveryNativeRPCErrorRetainsUnconfirmedCleanup() throws {
        for (code, type) in [(Int32(401), "AUTH_KEY_UNREGISTERED"), (406, "AUTH_KEY_DUPLICATED"), (403, "AUTHORIZATION_SCOPE_CHANGED"), (420, "FLOOD_WAIT_30"), (500, "INTERNAL")] {
            let o = try owned(); var starts = 0
            let adapter = transport(o, rpc: { _ in starts += 1; return .fail(MTRpcError(errorCode: code, errorDescription: type)) })
            unavailable(try value(AccountEnrollmentBridge.revokeSession(transport: adapter, accountManager: o.f.manager, coordinator: o.coordinator, cleanup: o.owner)))
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
            XCTAssertEqual(try o.coordinator.confirmedEnrollmentSessionKeys(o.owner), [])
        }
    }

    func testLateSuccessAfterKeyOrOwnerReplacementCannotMintProof() throws {
        for variant in 0 ... 1 {
            let o = try owned(); var starts = 0
            let newID = o.id.int64 ^ 1, replacement = try key(1, 0x54)
            let adapter = transport(o, rpc: { _ in
                starts += 1
                return o.f.manager.transaction { _ -> Void in
                    if variant == 0 { o.source.main = replacement }
                    else {
                        do {
                            try o.coordinator.acknowledgeEnrollmentCleanup(o.owner)
                            let permit = try o.coordinator.beginEnrollment(ticket: o.ticket)
                            try o.coordinator.bindEnrollment(permit, provisionalRecordID: newID, ticket: o.ticket)
                        } catch { XCTFail("component ownership replacement refused: \(error)") }
                    }
                } |> castError(MTRpcError.self)
            })
            unavailable(try value(AccountEnrollmentBridge.revokeSession(transport: adapter, accountManager: o.f.manager, coordinator: o.coordinator, cleanup: o.owner)))
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, variant == 0 ? o.id.int64 : newID)
            if variant == 0 { XCTAssertEqual(try o.coordinator.confirmedEnrollmentSessionKeys(o.owner), []) }
        }
    }

    func testDisposalWhileMetadataIsQueuedNeverStartsNativeRPC() throws {
        let o = try owned(); let starts = Atomic<Int>(value: 0), stops = Atomic<Int>(value: 0)
        let adapter = transport(o, stop: { _ = stops.modify { $0 + 1 } }, rpc: { _ in _ = starts.modify { $0 + 1 }; return .single(()) })
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), committed = expectation(description: "blocked metadata committed")
        let blocker = o.f.manager.transaction { _ -> Bool in entered.signal(); _ = release.wait(timeout: .now() + 3); return true }.start(next: { _ in committed.fulfill() })
        defer { release.signal(); blocker.dispose() }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let request = AccountEnrollmentBridge.revokeSession(transport: adapter, accountManager: o.f.manager, coordinator: o.coordinator, cleanup: o.owner).start(next: { _ in XCTFail("disposed result delivered") })
        request.dispose(); release.signal(); wait(for: [committed], timeout: 5)
        _ = try value(o.f.manager.transaction { _ in true })
        XCTAssertEqual(starts.with { $0 }, 0); XCTAssertEqual(stops.with { $0 }, 0)
    }

    func testOwnerChangedDuringKeyObservationCannotAuthorizeSubmission() throws {
        let o = try owned(); var starts = 0, stops = 0, observations = 0
        let adapter = transport(o, stop: { stops += 1 }, rpc: { _ in starts += 1; return .single(()) })
        o.source.onRead = {
            observations += 1
            if observations == 2 {
                // The first sample precedes the saved-key lookup; replace its
                // owner during the second sample, before final Core validation.
                do { try o.coordinator.acknowledgeEnrollmentCleanup(o.owner) }
                catch { XCTFail("fixture owner replacement refused: \(error)") }
            }
        }
        replyUnavailable(try value(adapter.logout()))
        XCTAssertEqual(observations, 2)
        XCTAssertEqual(starts, 0); XCTAssertEqual(stops, 0)
        XCTAssertNil(try o.coordinator.claimEnrollmentCleanup())
    }

    func testChangedNativeRootAfterConstructionCannotStopOrSubmit() throws {
        let o = try owned(); var starts = 0, stops = 0
        let adapter = transport(o, stop: { stops += 1 }, rpc: { _ in starts += 1; return .single(()) })
        XCTAssertTrue(adapter.isOriginalSessionCurrent)
        o.source.basePath += "/foreign"
        replyUnavailable(try value(adapter.logout()))
        XCTAssertEqual(starts, 0); XCTAssertEqual(stops, 0)
        XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
    }
}
