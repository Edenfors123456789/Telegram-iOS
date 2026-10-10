import XCTest
import Foundation
@testable import AccessModeCore
@testable import AccessModeAccountBridge
import TelegramCore
import MtProtoKit
import SwiftSignalKit

private final class BindingKeySource: AccountEnrollmentSessionKeySource {
    var recordID: Int64
    var environment: AccessModeCore.AccountEnvironment
    var basePath: String
    var key: AccountEnrollmentSessionKey?
    var onRead: (() -> Void)?
    var extraKeys: [Int32: AccountEnrollmentSessionKey] = [:]
    init(fixture: BridgeFixture, id: AccountRecordId, key: AccountEnrollmentSessionKey?) {
        recordID = id.int64; environment = .production; self.key = key
        basePath = fixture.directory.appendingPathComponent(accountRecordIdPathName(id)).path
    }
    func persistentFingerprint() -> AccountEnrollmentSessionKey? { onRead?(); return key }
    func persistentFingerprint(datacenterID: Int32) -> AccountEnrollmentSessionKey? {
        if let key, key.datacenterID == datacenterID { return key }
        return extraKeys[datacenterID]
    }
}

final class AccountEnrollmentSessionBindingTests: XCTestCase {
    func testOriginalKeyReconciliationAfterReopenIsReadOnlyAndRequiresAllSavedKeys() throws {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), t = try ready(c)
        let (id, permit) = try create(f, c, t), first = try key(), second = try key(2, byte: 0x52)
        try c.bindEnrollmentSessionKey(permit, sessionKey: first, ticket: t)
        try c.bindEnrollmentSessionKey(permit, sessionKey: second, ticket: t)
        try c.lock()
        let reopenedStore = try AccessCredentialStore(directory: f.directory.appendingPathComponent("vault"), namespace: "test.account-bridge", keyProvider: f.keys, iterations: 600_000)
        let reopened = AccessModeCoordinator(store: reopenedStore), cleanup = try XCTUnwrap(reopened.claimEnrollmentCleanup())
        _ = try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: reopened, cleanup: cleanup))
        let source = BindingKeySource(fixture: f, id: id, key: first)
        let before = try Data(contentsOf: f.directory.appendingPathComponent("vault/access-state.v1.enc"))
        XCTAssertFalse(try value(AccountEnrollmentBridge.reconcileOriginalSessionKeys(source: source, accountManager: f.manager,
            coordinator: reopened, cleanup: cleanup)))
        source.extraKeys[2] = second
        XCTAssertTrue(try value(AccountEnrollmentBridge.reconcileOriginalSessionKeys(source: source, accountManager: f.manager,
            coordinator: reopened, cleanup: cleanup)))
        XCTAssertEqual(try reopened.boundEnrollmentSessionKeys(cleanup), [first, second])
        XCTAssertEqual(reopened.state, .locked)
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("vault/access-state.v1.enc")), before)
        source.key = try key(byte: 0x53)
        XCTAssertFalse(try value(AccountEnrollmentBridge.reconcileOriginalSessionKeys(source: source, accountManager: f.manager,
            coordinator: reopened, cleanup: cleanup)))
    }

    func testUnboundAttachedForeignAndWrongNativeSourcesCannotReconcile() throws {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), t = try ready(c)
        let (id, permit) = try create(f, c, t), original = try key()
        let source = BindingKeySource(fixture: f, id: id, key: original)
        try c.bindEnrollmentSessionKey(permit, sessionKey: original, ticket: t)
        let cleanup = try XCTUnwrap(c.claimEnrollmentCleanup())
        XCTAssertFalse(try value(AccountEnrollmentBridge.reconcileOriginalSessionKeys(source: source, accountManager: f.manager,
            coordinator: c, cleanup: cleanup)), "Owned auth must be detached first")
        _ = try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: c, cleanup: cleanup))
        let share = AccessModeCoordinator(store: f.store, process: .shareExtension)
        XCTAssertFalse(try value(AccountEnrollmentBridge.reconcileOriginalSessionKeys(source: source, accountManager: f.manager,
            coordinator: share, cleanup: cleanup)))
        source.environment = .test
        XCTAssertFalse(try value(AccountEnrollmentBridge.reconcileOriginalSessionKeys(source: source, accountManager: f.manager,
            coordinator: c, cleanup: cleanup)))
        source.environment = .production; source.basePath += "/foreign"
        XCTAssertFalse(try value(AccountEnrollmentBridge.reconcileOriginalSessionKeys(source: source, accountManager: f.manager,
            coordinator: c, cleanup: cleanup)))
        XCTAssertEqual(try c.boundEnrollmentSessionKeys(cleanup), [original])
    }

    func testAnOldLedgerCannotAcquireInventedKeysDuringReconciliation() throws {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), t = try ready(c)
        let (id, _) = try create(f, c, t), source = BindingKeySource(fixture: f, id: id, key: try key())
        let cleanup = try XCTUnwrap(c.claimEnrollmentCleanup())
        _ = try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: c, cleanup: cleanup))
        let before = try Data(contentsOf: f.directory.appendingPathComponent("vault/access-state.v1.enc"))
        XCTAssertFalse(try value(AccountEnrollmentBridge.reconcileOriginalSessionKeys(source: source, accountManager: f.manager,
            coordinator: c, cleanup: cleanup)))
        XCTAssertEqual(try c.boundEnrollmentSessionKeys(cleanup), [])
        XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("vault/access-state.v1.enc")), before)
    }

    private func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let done = expectation(description: "Binding metadata result")
        var result: T?
        let disposable = signal.start(next: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        disposable.dispose()
        return try XCTUnwrap(result)
    }
    private func ready(_ coordinator: AccessModeCoordinator) throws -> AccessTicket {
        let ticket = try coordinator.beginUnlock(pin: "123456")
        try coordinator.completePreparation(ticket)
        return ticket
    }
    private func create(_ f: BridgeFixture, _ c: AccessModeCoordinator, _ t: AccessTicket) throws -> (AccountRecordId, AccountEnrollmentPermit) {
        let created = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager,
            coordinator: c, ticket: t, environment: .production))
        guard case let .created(id, permit) = created else { throw AccessError.unavailable }
        return (id, permit)
    }
    private func key(_ dc: Int32 = 1, byte: UInt8 = 0x51) throws -> AccountEnrollmentSessionKey {
        try .init(datacenterID: dc, digest: Data(repeating: byte, count: 32))
    }

    func testRealAuthInfoAcceptsOnlyFullLengthPermanentKeysAndHashesTheBytes() throws {
        let raw = Data(repeating: 0x51, count: 256)
        let info = try XCTUnwrap(MTDatacenterAuthInfo(authKey: raw, authKeyId: 42,
            validUntilTimestamp: Int32.max, saltSet: [], authKeyAttributes: [:]))
        let actual = try XCTUnwrap(AccountEnrollmentBridge.persistentFingerprint(datacenterID: 2, authInfo: info))
        XCTAssertEqual(actual.datacenterID, 2)
        // Independent known SHA-256 vector generated with Python hashlib.
        let expected: [UInt8] = [0x98, 0xbd, 0x3b, 0x0a, 0xa6, 0x2e, 0x65, 0x42,
            0xed, 0x6a, 0xcd, 0x8d, 0x29, 0x7e, 0xf2, 0xe5, 0xf7, 0x1f, 0x19, 0x1b,
            0x45, 0x8d, 0xcb, 0x11, 0x0a, 0x82, 0xd1, 0xbf, 0x47, 0x2e, 0x6f, 0xd0]
        XCTAssertEqual(actual.digest, Data(expected))
        XCTAssertNotEqual(actual.digest, raw)
        XCTAssertNil(AccountEnrollmentBridge.persistentFingerprint(datacenterID: 0, authInfo: info))
        XCTAssertNil(AccountEnrollmentBridge.persistentFingerprint(datacenterID: Int(Int32.max) + 1, authInfo: info))
        XCTAssertNil(AccountEnrollmentBridge.persistentFingerprint(datacenterID: 2, authInfo: nil))
        for size in [0, 32, 255, 257] {
            let bad = MTDatacenterAuthInfo(authKey: Data(repeating: 0x51, count: size), authKeyId: 42,
                validUntilTimestamp: Int32.max, saltSet: [], authKeyAttributes: [:])
            XCTAssertNil(AccountEnrollmentBridge.persistentFingerprint(datacenterID: 2, authInfo: bad))
        }
        let temporary = MTDatacenterAuthInfo(authKey: raw, authKeyId: 42,
            validUntilTimestamp: 1000, saltSet: [], authKeyAttributes: [:])
        XCTAssertNil(AccountEnrollmentBridge.persistentFingerprint(datacenterID: 2, authInfo: temporary))
    }

    func testCurrentNativeRecordPersistsBindingBeforeReportingSuccessAndSurvivesReopen() throws {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), t = try ready(c)
        let (id, permit) = try create(f, c, t), original = try key()
        let source = BindingKeySource(fixture: f, id: id, key: original)
        let request = AccountEnrollmentBridge.bindOriginalSessionKey(source: source, accountManager: f.manager,
            coordinator: c, permit: permit, ticket: t)
        XCTAssertTrue(try value(request))
        XCTAssertEqual(try f.store.file.read().pendingEnrollmentCleanup?.sessionKeys, [original])
        XCTAssertFalse(try value(request), "A retained binding request is single-use")
        try c.lock()
        let store = try AccessCredentialStore(directory: f.directory.appendingPathComponent("vault"), namespace: "test.account-bridge",
            keyProvider: f.keys, iterations: 600_000)
        let reopened = AccessModeCoordinator(store: store), cleanup = try XCTUnwrap(reopened.claimEnrollmentCleanup())
        XCTAssertEqual(try reopened.boundEnrollmentSessionKeys(cleanup), [original])
        XCTAssertEqual(reopened.state, .locked)
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), id)
    }

    func testWrongRecordEnvironmentDirectoryAndMissingKeyCannotWriteBinding() throws {
        for failure in 0 ... 3 {
            let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), t = try ready(c)
            let (id, permit) = try create(f, c, t), source = BindingKeySource(fixture: f, id: id, key: try key())
            switch failure {
            case 0: source.recordID ^= 1
            case 1: source.environment = .test
            case 2: source.basePath = f.directory.appendingPathComponent("another-account").path
            default: source.key = nil
            }
            XCTAssertFalse(try value(AccountEnrollmentBridge.bindOriginalSessionKey(source: source, accountManager: f.manager,
                coordinator: c, permit: permit, ticket: t)))
            XCTAssertNil(try f.store.file.read().pendingEnrollmentCleanup?.sessionKeys)
            XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), id)
        }
    }

    func testPromotedOrReplacedAuthMetadataCannotAdoptAKey() throws {
        for replacement in [false, true] {
            let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), t = try ready(c)
            let (id, permit) = try create(f, c, t), source = BindingKeySource(fixture: f, id: id, key: try key())
            _ = try value(f.manager.transaction { transaction -> Void in
                transaction.removeAuth()
                if replacement { _ = transaction.createAuth([]) }
                else { transaction.updateRecord(id, { _ in AccountRecord(id: id, attributes: [], temporarySessionId: nil) }) }
            })
            XCTAssertFalse(try value(AccountEnrollmentBridge.bindOriginalSessionKey(source: source, accountManager: f.manager,
                coordinator: c, permit: permit, ticket: t)))
            XCTAssertNil(try f.store.file.read().pendingEnrollmentCleanup?.sessionKeys)
        }
    }

    func testStalePermitShareAndKeyReplacementRetainOnlyTheOriginalOwner() throws {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), t = try ready(c)
        let (id, permit) = try create(f, c, t), original = try key()
        let source = BindingKeySource(fixture: f, id: id, key: original)
        XCTAssertTrue(try value(AccountEnrollmentBridge.bindOriginalSessionKey(source: source, accountManager: f.manager,
            coordinator: c, permit: permit, ticket: t)))
        source.key = try key(byte: 0x52)
        XCTAssertFalse(try value(AccountEnrollmentBridge.bindOriginalSessionKey(source: source, accountManager: f.manager,
            coordinator: c, permit: permit, ticket: t)))
        let cleanup = try XCTUnwrap(c.claimEnrollmentCleanup())
        XCTAssertEqual(try c.boundEnrollmentSessionKeys(cleanup), [original])
        source.key = original
        XCTAssertFalse(try value(AccountEnrollmentBridge.bindOriginalSessionKey(source: source, accountManager: f.manager,
            coordinator: c, permit: permit, ticket: t)))
        let share = AccessModeCoordinator(store: f.store, process: .shareExtension), s = try ready(share)
        XCTAssertFalse(try value(AccountEnrollmentBridge.bindOriginalSessionKey(source: source, accountManager: f.manager,
            coordinator: share, permit: permit, ticket: s)))
        XCTAssertEqual(try c.boundEnrollmentSessionKeys(cleanup), [original])
    }

    func testDisposedQueuedBindingDoesNotWriteOrPublish() throws {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), t = try ready(c)
        let (id, permit) = try create(f, c, t), source = BindingKeySource(fixture: f, id: id, key: try key())
        let began = expectation(description: "Metadata blocked"), release = DispatchSemaphore(value: 0)
        let blocker = f.manager.transaction { _ -> Void in
            began.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }.start()
        defer { release.signal(); blocker.dispose() }
        wait(for: [began], timeout: 3)
        let binding = AccountEnrollmentBridge.bindOriginalSessionKey(source: source, accountManager: f.manager,
            coordinator: c, permit: permit, ticket: t).start(next: { _ in XCTFail("Disposed binding delivered a result") })
        binding.dispose(); release.signal()
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), id)
        XCTAssertNil(try f.store.file.read().pendingEnrollmentCleanup?.sessionKeys)
    }

    func testKeyChangingDuringPersistenceCannotReportSuccessOrReplaceTheSavedOriginal() throws {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), t = try ready(c)
        let (id, permit) = try create(f, c, t), original = try key(), changed = try key(byte: 0x52)
        let source = BindingKeySource(fixture: f, id: id, key: original)
        var reads = 0
        source.onRead = { reads += 1; if reads == 2 { source.key = changed } }
        XCTAssertFalse(try value(AccountEnrollmentBridge.bindOriginalSessionKey(source: source, accountManager: f.manager,
            coordinator: c, permit: permit, ticket: t)))
        XCTAssertEqual(c.state, .locked)
        let cleanup = try XCTUnwrap(c.claimEnrollmentCleanup())
        XCTAssertEqual(try c.boundEnrollmentSessionKeys(cleanup), [original])
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), id)
    }

    func testDisposalDuringPersistenceKeepsBindingButCancelsCompletionAuthority() throws {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store), t = try ready(c)
        let (id, permit) = try create(f, c, t), original = try key()
        let source = BindingKeySource(fixture: f, id: id, key: original)
        let began = expectation(description: "Key binding write began"), release = DispatchSemaphore(value: 0)
        f.keys.loads = 0
        f.keys.onLoad = {
            if f.keys.loads == 2 { began.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success) }
        }
        defer { release.signal(); f.keys.onLoad = nil }
        let binding = AccountEnrollmentBridge.bindOriginalSessionKey(source: source, accountManager: f.manager,
            coordinator: c, permit: permit, ticket: t).start(next: { _ in XCTFail("Disposed binding delivered a result") })
        wait(for: [began], timeout: 3)
        binding.dispose(); release.signal()
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), id)
        f.keys.onLoad = nil
        XCTAssertNil(try f.store.file.read().pendingEnrollment)
        let cleanup = try XCTUnwrap(c.claimEnrollmentCleanup())
        XCTAssertEqual(try c.boundEnrollmentSessionKeys(cleanup), [original])
    }
}
