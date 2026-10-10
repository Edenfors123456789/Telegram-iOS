import XCTest
import Foundation
@testable import AccessModeCore
@testable import AccessModeAccountBridge
@testable import TelegramCore
import SwiftSignalKit

private struct CompletionFixture {
    let f: BridgeFixture
    let coordinator: AccessModeCoordinator
    let id: AccountRecordId
    let owner: AccountEnrollmentCleanupTicket
    let keys: [AccountEnrollmentSessionKey]
}

/// Offline fixtures: receipts are recorded directly, simulating the verified
/// native logout boundary. No Telegram session is authorized or revoked.
final class AccountEnrollmentCompletionTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let done = expectation(description: "completion result")
        let result = Atomic<T?>(value: nil)
        let disposable = signal.start(next: { _ = result.swap($0); done.fulfill() })
        wait(for: [done], timeout: 5); disposable.dispose()
        return try XCTUnwrap(result.with { $0 }, file: file, line: line)
    }
    private func key(_ dc: Int32, _ byte: UInt8) throws -> AccountEnrollmentSessionKey {
        try AccountEnrollmentSessionKey(datacenterID: dc, digest: Data(repeating: byte, count: 32))
    }
    private func owned(keyCount: Int = 2, promote: Bool = true, detach: Bool = true, attempted: Bool = true) throws -> CompletionFixture {
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
        let owner = try XCTUnwrap(c.claimEnrollmentCleanup())
        if detach {
            XCTAssertEqual(try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: c, cleanup: owner)), .detached)
        }
        return CompletionFixture(f: f, coordinator: c, id: id, owner: owner, keys: keys)
    }
    private func revokeAll(_ o: CompletionFixture) throws {
        for key in o.keys { try o.coordinator.recordEnrollmentSessionRevocation(o.owner, sessionKey: key) }
    }
    private func complete(_ o: CompletionFixture, coordinator: AccessModeCoordinator? = nil) throws -> AccountEnrollmentCleanupCompletion {
        try value(AccountEnrollmentBridge.completeProvisionalCleanup(accountManager: o.f.manager, coordinator: coordinator ?? o.coordinator, cleanup: o.owner))
    }
    private func recordIDs(_ o: CompletionFixture) throws -> [AccountRecordId] {
        try value(o.f.manager.transaction { $0.getRecords().map(\.id) })
    }
    private func directoryExists(_ o: CompletionFixture) -> Bool {
        FileManager.default.fileExists(atPath: o.f.directory.appendingPathComponent(accountRecordIdPathName(o.id)).path)
    }

    func testAnUnrevokedKeyKeepsTheRecordLedgerAndDirectory() throws {
        let o = try owned()
        try o.coordinator.recordEnrollmentSessionRevocation(o.owner, sessionKey: o.keys[0])
        XCTAssertEqual(try complete(o), .awaitingRevocation)
        XCTAssertEqual(try recordIDs(o), [o.id], "the second datacenter's session may still be live")
        XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
        XCTAssertTrue(directoryExists(o))
        XCTAssertNil(try o.coordinator.withUnownedAccountDirectory(recordID: o.id.int64) { true })
    }

    func testCompletionRemovesOnlyTheOwnedRecordAndReleasesItsDirectory() throws {
        let o = try owned(), unrelated = AccountRecordId(rawValue: 77)
        let other = try value(o.f.manager.transaction { transaction -> AccountRecordId? in
            transaction.updateRecord(unrelated, { _ in AccountRecord(id: unrelated, attributes: [], temporarySessionId: nil) })
            return transaction.createAuth([])?.id
        })
        try revokeAll(o)
        XCTAssertEqual(try complete(o), .completed)
        XCTAssertEqual(try recordIDs(o), [unrelated])
        XCTAssertEqual(try value(o.f.manager.transaction { $0.getCurrentAuth()?.id }), other)
        XCTAssertNil(try o.coordinator.claimEnrollmentCleanup())
        // Local data is not deleted here; the gated background cleanup may now remove it.
        XCTAssertTrue(directoryExists(o))
        XCTAssertEqual(try o.coordinator.withUnownedAccountDirectory(recordID: o.id.int64) { true }, true)
        XCTAssertEqual(try complete(o), .unavailable, "a resolved owner cannot complete twice")
    }

    func testAnUnpromotedOrNeverBoundOwnerCompletes() throws {
        let unpromoted = try owned(promote: false)
        try revokeAll(unpromoted)
        XCTAssertEqual(try complete(unpromoted), .completed)
        XCTAssertEqual(try recordIDs(unpromoted), [])
        XCTAssertNil(try unpromoted.coordinator.claimEnrollmentCleanup())
        let unbound = try owned(keyCount: 0, promote: false)
        XCTAssertEqual(try complete(unbound), .completed)
        XCTAssertNil(try unbound.coordinator.claimEnrollmentCleanup())
    }

    func testKeysNeverUsedForSignInNeedNoReceipt() throws {
        // Cancelled before sign-in (or the key a datacenter migration left
        // behind): the key was never sent an authorizing request.
        let o = try owned(promote: false, attempted: false)
        XCTAssertEqual(try o.coordinator.boundEnrollmentSessionKeys(o.owner).count, 2)
        XCTAssertEqual(try complete(o), .completed)
        XCTAssertNil(try o.coordinator.claimEnrollmentCleanup())
    }

    func testAttachedAuthOrAnAmbiguousRecordRefusesWithoutChanges() throws {
        let attached = try owned(promote: false, detach: false)
        try revokeAll(attached)
        XCTAssertEqual(try complete(attached), .unavailable)
        XCTAssertEqual(try value(attached.f.manager.transaction { $0.getCurrentAuth()?.id }), attached.id)
        XCTAssertEqual(try attached.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, attached.id.int64)

        let ambiguous = try owned()
        _ = try value(ambiguous.f.manager.transaction { transaction -> Bool in
            transaction.updateRecord(ambiguous.id, { _ in AccountRecord(id: ambiguous.id, attributes: [
                .environment(AccountEnvironmentAttribute(environment: .test))
            ], temporarySessionId: nil) })
            return true
        })
        try revokeAll(ambiguous)
        XCTAssertEqual(try complete(ambiguous), .unavailable)
        XCTAssertEqual(try recordIDs(ambiguous), [ambiguous.id])
        XCTAssertEqual(try ambiguous.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, ambiguous.id.int64)
    }

    func testForeignReopenedAndShareCoordinatorsCannotComplete() throws {
        let o = try owned()
        try revokeAll(o)
        let foreign = try BridgeFixture()
        for denied in [AccessModeCoordinator(store: foreign.store), AccessModeCoordinator(store: try AccessCredentialStore(directory: o.f.directory.appendingPathComponent("vault"),
                           namespace: "test.account-bridge", keyProvider: o.f.keys, iterations: 600_000)),
                       AccessModeCoordinator(store: o.f.store, process: .shareExtension)] {
            XCTAssertEqual(try complete(o, coordinator: denied), .unavailable)
            XCTAssertEqual(try recordIDs(o), [o.id])
        }
        XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64)
        XCTAssertEqual(try complete(o), .completed)
    }

    func testAFailedVaultAccessKeepsTheLedgerForAnExactRetry() throws {
        var interruptedAfterRemoval = false
        for offset in 1 ... 8 {
            let o = try owned()
            try revokeAll(o)
            o.f.keys.failOnLoad = o.f.keys.loads + offset
            let result = try complete(o)
            o.f.keys.failOnLoad = nil
            switch result {
            case .completed:
                XCTAssertNil(try o.coordinator.claimEnrollmentCleanup(), "offset \(offset)")
            case .unavailable, .awaitingRevocation:
                XCTAssertEqual(try o.coordinator.claimEnrollmentCleanup()?.provisionalRecordID, o.id.int64, "offset \(offset)")
                if try recordIDs(o).isEmpty { interruptedAfterRemoval = true }
                XCTAssertEqual(try complete(o), .completed, "offset \(offset)")
                XCTAssertEqual(try recordIDs(o), [])
            }
        }
        XCTAssertTrue(interruptedAfterRemoval, "no failure between record removal and acknowledgment was exercised")
    }
}
