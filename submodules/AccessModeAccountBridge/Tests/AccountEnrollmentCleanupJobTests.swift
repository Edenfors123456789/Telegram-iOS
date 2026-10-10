import XCTest
import Foundation
@testable import AccessModeCore
@testable import AccessModeAccountBridge
@testable import TelegramCore
import SwiftSignalKit

private struct JobFixture {
    let f: BridgeFixture
    let coordinator: AccessModeCoordinator
    let id: AccountRecordId
    let owner: AccountEnrollmentCleanupTicket
    let keys: [AccountEnrollmentSessionKey]
}

/// Offline fixtures: the injected revocation records receipts directly,
/// simulating the verified native logout. No Telegram session is involved.
final class AccountEnrollmentCleanupJobTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let done = expectation(description: "job result")
        let result = Atomic<T?>(value: nil)
        let disposable = signal.start(next: { _ = result.swap($0); done.fulfill() })
        wait(for: [done], timeout: 5); disposable.dispose()
        return try XCTUnwrap(result.with { $0 }, file: file, line: line)
    }
    private func key(_ dc: Int32, _ byte: UInt8) throws -> AccountEnrollmentSessionKey {
        try AccountEnrollmentSessionKey(datacenterID: dc, digest: Data(repeating: byte, count: 32))
    }
    /// Claimed but still attached: the job itself must detach first.
    private func owned(keyCount: Int = 2, attempted: Bool = true, promote: Bool = false) throws -> JobFixture {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store)
        let t = try c.beginUnlock(pin: "123456"); try c.completePreparation(t)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: c, ticket: t, environment: .production))
        guard case let .created(id, permit) = creation else { throw AccessError.unavailable }
        let keys = try (0 ..< keyCount).map { try key(Int32($0 + 1), UInt8(0x51 + $0)) }
        for key in keys {
            try c.bindEnrollmentSessionKey(permit, sessionKey: key, ticket: t)
            if attempted { try c.markEnrollmentAuthorizationAttempt(permit, sessionKey: key, ticket: t) }
        }
        if promote {
            XCTAssertTrue(try value(f.manager.transaction { switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: false, isSupportUser: false) }))
        }
        return JobFixture(f: f, coordinator: c, id: id, owner: try XCTUnwrap(c.claimEnrollmentCleanup()), keys: keys)
    }
    private func run(_ o: JobFixture, coordinator: AccessModeCoordinator? = nil,
        revoke: @escaping (AccountEnrollmentSessionKey) -> Signal<Void, NoError>) throws -> AccountEnrollmentCleanupJobResult {
        try value(AccountEnrollmentBridge.runProvisionalCleanup(accountManager: o.f.manager, coordinator: coordinator ?? o.coordinator,
            cleanup: o.owner, revoke: revoke))
    }
    /// A revocation that succeeds the way the verified native one does: by
    /// leaving a durable receipt behind.
    private func recording(_ o: JobFixture, _ calls: Atomic<[AccountEnrollmentSessionKey]>) -> (AccountEnrollmentSessionKey) -> Signal<Void, NoError> {
        return { key in
            _ = calls.modify { $0 + [key] }
            try? o.coordinator.recordEnrollmentSessionRevocation(o.owner, sessionKey: key)
            return .single(())
        }
    }
    private func recordIDs(_ o: JobFixture) throws -> [AccountRecordId] {
        try value(o.f.manager.transaction { $0.getRecords().map(\.id) })
    }

    func testDetachesRevokesEachAttemptedKeyAndCompletes() throws {
        let o = try owned(promote: true), calls = Atomic<[AccountEnrollmentSessionKey]>(value: [])
        XCTAssertEqual(try run(o, revoke: recording(o, calls)), .completed)
        XCTAssertEqual(calls.with { $0 }, o.keys)
        XCTAssertEqual(try recordIDs(o), [])
        XCTAssertNil(try value(o.f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertNil(try o.coordinator.claimEnrollmentCleanup())
    }

    func testKeysNeverUsedForSignInAreNotRevoked() throws {
        let o = try owned(attempted: false), calls = Atomic<[AccountEnrollmentSessionKey]>(value: [])
        XCTAssertEqual(try run(o, revoke: recording(o, calls)), .completed)
        XCTAssertEqual(calls.with { $0 }, [])
        XCTAssertNil(try o.coordinator.claimEnrollmentCleanup())
    }

    func testAlreadyConfirmedKeysAreNotRevokedAgain() throws {
        let o = try owned(), calls = Atomic<[AccountEnrollmentSessionKey]>(value: [])
        try o.coordinator.recordEnrollmentSessionRevocation(o.owner, sessionKey: o.keys[0])
        XCTAssertEqual(try run(o, revoke: recording(o, calls)), .completed)
        XCTAssertEqual(calls.with { $0 }, [o.keys[1]])
    }

    func testAnUnconfirmedRevocationStopsAndLeavesEverythingForARetry() throws {
        let o = try owned(promote: true), calls = Atomic<[AccountEnrollmentSessionKey]>(value: [])
        // Claims success but leaves no receipt: the job trusts only Core.
        let unconfirmed: (AccountEnrollmentSessionKey) -> Signal<Void, NoError> = { key in
            _ = calls.modify { $0 + [key] }
            return .single(())
        }
        XCTAssertEqual(try run(o, revoke: unconfirmed), .retryLater)
        XCTAssertEqual(calls.with { $0 }, [o.keys[0]], "the next key waits for the previous one")
        XCTAssertEqual(try recordIDs(o), [o.id])
        XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
        XCTAssertEqual(try o.coordinator.confirmedEnrollmentSessionKeys(o.owner), [])
        let retried = Atomic<[AccountEnrollmentSessionKey]>(value: [])
        XCTAssertEqual(try run(o, revoke: recording(o, retried)), .completed)
        XCTAssertEqual(retried.with { $0 }, o.keys)
        XCTAssertEqual(try recordIDs(o), [])
    }

    func testAnEmptyRevocationSignalIsNotASuccess() throws {
        let o = try owned(keyCount: 1)
        XCTAssertEqual(try run(o, revoke: { _ in .complete() }), .retryLater)
        XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
    }

    private func unclaimed() throws -> (f: BridgeFixture, coordinator: AccessModeCoordinator, ticket: AccessTicket, id: AccountRecordId, key: AccountEnrollmentSessionKey) {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store)
        let t = try c.beginUnlock(pin: "123456"); try c.completePreparation(t)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: c, ticket: t, environment: .production))
        guard case let .created(id, permit) = creation else { throw AccessError.unavailable }
        let k = try key(1, 0x51)
        try c.bindEnrollmentSessionKey(permit, sessionKey: k, ticket: t)
        try c.markEnrollmentAuthorizationAttempt(permit, sessionKey: k, ticket: t)
        return (f, c, t, id, k)
    }
    private func recover(_ manager: AccountManager<TelegramAccountManagerTypes>, _ coordinator: AccessModeCoordinator,
        _ calls: Atomic<[AccountEnrollmentSessionKey]>) throws -> AccountEnrollmentCleanupJobResult? {
        try value(AccountEnrollmentBridge.recoverProvisionalCleanup(accountManager: manager, coordinator: coordinator, revocation: { owner in
            return { key in
                _ = calls.modify { $0 + [key] }
                try? coordinator.recordEnrollmentSessionRevocation(owner, sessionKey: key)
                return .single(())
            }
        }))
    }

    func testRecoveryWithoutALeftoverOwnerDoesNothing() throws {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), calls = Atomic<[AccountEnrollmentSessionKey]>(value: [])
        XCTAssertNil(try recover(f.manager, c, calls))
        XCTAssertEqual(calls.with { $0 }, [])
        // Nothing here touches AccountManager; let its initialization drain
        // before the temporary directory is removed.
        _ = try value(f.manager.transaction { _ in true })
    }

    func testRecoveryClaimsALeftoverFlowCompletesItAndFreesEnrollment() throws {
        // The flow's process is gone; a fresh coordinator models the relaunch.
        let o = try unclaimed(), calls = Atomic<[AccountEnrollmentSessionKey]>(value: [])
        let relaunched = AccessModeCoordinator(store: try AccessCredentialStore(directory: o.f.directory.appendingPathComponent("vault"),
            namespace: "test.account-bridge", keyProvider: o.f.keys, iterations: 600_000))
        XCTAssertEqual(try recover(o.f.manager, relaunched, calls), .completed)
        XCTAssertEqual(calls.with { $0 }, [o.key])
        XCTAssertNil(try value(o.f.manager.transaction { $0.getCurrentAuth() }))
        XCTAssertNil(try relaunched.claimEnrollmentCleanup())
        let t = try relaunched.beginUnlock(pin: "123456"); try relaunched.completePreparation(t)
        XCTAssertNoThrow(try relaunched.beginEnrollment(ticket: t), "a resolved owner no longer blocks enrollment")
    }

    func testShareCannotRecover() throws {
        let o = try unclaimed(), calls = Atomic<[AccountEnrollmentSessionKey]>(value: [])
        let share = AccessModeCoordinator(store: o.f.store, process: .shareExtension)
        XCTAssertEqual(try recover(o.f.manager, share, calls), .unavailable)
        XCTAssertEqual(calls.with { $0 }, [])
        XCTAssertEqual(try value(o.f.manager.transaction { $0.getCurrentAuth()?.id }), o.id)
        XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
    }

    func testAForeignOrShareCoordinatorRevokesNothing() throws {
        let o = try owned(), calls = Atomic<[AccountEnrollmentSessionKey]>(value: [])
        let foreign = try BridgeFixture()
        for denied in [AccessModeCoordinator(store: foreign.store), AccessModeCoordinator(store: o.f.store, process: .shareExtension)] {
            XCTAssertEqual(try run(o, coordinator: denied, revoke: recording(o, calls)), .unavailable)
        }
        XCTAssertEqual(calls.with { $0 }, [])
        XCTAssertEqual(try value(o.f.manager.transaction { $0.getCurrentAuth()?.id }), o.id, "a refused job must not detach")
        XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
    }
}
