import XCTest
import Foundation
@testable import AccessModeCore
@testable import AccessModeAccountBridge
import TelegramCore
import SwiftSignalKit

private final class AttemptKeySource: AccountEnrollmentSessionKeySource {
    var recordID: Int64
    var environment: AccessModeCore.AccountEnvironment = .production
    var basePath: String
    var key: AccountEnrollmentSessionKey?
    var onRead: (() -> Void)?
    init(fixture: BridgeFixture, id: AccountRecordId, key: AccountEnrollmentSessionKey?) {
        recordID = id.int64; self.key = key
        basePath = fixture.directory.appendingPathComponent(accountRecordIdPathName(id)).path
    }
    func persistentFingerprint() -> AccountEnrollmentSessionKey? { onRead?(); return key }
}

/// The enrollment screen calls this before every request that may authorize
/// the provisional account's key. Offline fixtures; no network.
final class AuthorizationAttemptPreparationTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let done = expectation(description: "preparation result")
        let result = Atomic<T?>(value: nil)
        let disposable = signal.start(next: { _ = result.swap($0); done.fulfill() })
        wait(for: [done], timeout: 5); disposable.dispose()
        return try XCTUnwrap(result.with { $0 })
    }
    private func key(_ dc: Int32 = 1, _ byte: UInt8 = 0x51) throws -> AccountEnrollmentSessionKey {
        try AccountEnrollmentSessionKey(datacenterID: dc, digest: Data(repeating: byte, count: 32))
    }
    private func flow() throws -> (f: BridgeFixture, c: AccessModeCoordinator, t: AccessTicket, id: AccountRecordId, permit: AccountEnrollmentPermit) {
        let f = try BridgeFixture(), c = AccessModeCoordinator(store: f.store)
        let t = try c.beginUnlock(pin: "123456"); try c.completePreparation(t)
        let created = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: c, ticket: t, environment: .production))
        guard case let .created(id, permit) = created else { throw AccessError.unavailable }
        return (f, c, t, id, permit)
    }
    private func prepare(_ o: (f: BridgeFixture, c: AccessModeCoordinator, t: AccessTicket, id: AccountRecordId, permit: AccountEnrollmentPermit),
        _ source: AttemptKeySource, coordinator: AccessModeCoordinator? = nil) throws -> Bool {
        try value(AccountEnrollmentBridge.prepareAuthorizationAttempt(source: source, accountManager: o.f.manager,
            coordinator: coordinator ?? o.c, permit: o.permit, ticket: o.t))
    }

    func testPreparationBindsAndMarksTheCurrentMainKey() throws {
        let o = try flow(), k = try key(), source = AttemptKeySource(fixture: o.f, id: o.id, key: k)
        XCTAssertTrue(try prepare(o, source))
        XCTAssertTrue(try prepare(o, source), "repeating before every request is fine")
        let claim = try XCTUnwrap(o.c.claimEnrollmentCleanup())
        XCTAssertEqual(try o.c.boundEnrollmentSessionKeys(claim), [k])
        XCTAssertEqual(try o.c.enrollmentSessionKeysRequiringRevocation(claim), [k])
    }

    func testAKeyUsedOnlyBeforeAMigrationIsNeverMarked() throws {
        // sendCode is not authorizing: it may move the account to another
        // datacenter, and only the key in use afterwards is prepared.
        let o = try flow(), migrated = try key(2, 0x52), source = AttemptKeySource(fixture: o.f, id: o.id, key: try key())
        source.key = migrated
        XCTAssertTrue(try prepare(o, source))
        let claim = try XCTUnwrap(o.c.claimEnrollmentCleanup())
        XCTAssertEqual(try o.c.boundEnrollmentSessionKeys(claim), [migrated])
        XCTAssertEqual(try o.c.enrollmentSessionKeysRequiringRevocation(claim), [migrated])
    }

    func testNoKeyYetRefusesWithoutWriting() throws {
        let o = try flow(), source = AttemptKeySource(fixture: o.f, id: o.id, key: nil)
        XCTAssertFalse(try prepare(o, source))
        let claim = try XCTUnwrap(o.c.claimEnrollmentCleanup())
        XCTAssertEqual(try o.c.boundEnrollmentSessionKeys(claim), [])
    }

    func testAKeyChangingDuringPreparationRefusesAndLocks() throws {
        let o = try flow(), source = AttemptKeySource(fixture: o.f, id: o.id, key: try key()), replacement = try key(1, 0x53)
        var reads = 0
        source.onRead = { reads += 1; if reads == 2 { source.key = replacement } }
        XCTAssertFalse(try prepare(o, source))
        XCTAssertEqual(o.c.state, .locked)
        let claim = try XCTUnwrap(o.c.claimEnrollmentCleanup())
        XCTAssertEqual(try o.c.enrollmentSessionKeysRequiringRevocation(claim), [], "a key that changed is not the one a request will use")
    }

    func testOnlyTheOwnedAttachedProvisionalAuthCanBePrepared() throws {
        let o = try flow(), k = try key()
        let foreignPath = AttemptKeySource(fixture: o.f, id: o.id, key: k)
        foreignPath.basePath += "/elsewhere"
        XCTAssertFalse(try prepare(o, foreignPath))
        let otherRecord = AttemptKeySource(fixture: o.f, id: AccountRecordId(rawValue: o.id.int64 ^ 1), key: k)
        XCTAssertFalse(try prepare(o, otherRecord))
        let share = AccessModeCoordinator(store: o.f.store, process: .shareExtension)
        XCTAssertFalse(try prepare(o, AttemptKeySource(fixture: o.f, id: o.id, key: k), coordinator: share))
        _ = try value(o.f.manager.transaction { $0.removeAuth() })
        XCTAssertFalse(try prepare(o, AttemptKeySource(fixture: o.f, id: o.id, key: k)), "a detached flow must not send anything")
        let claim = try XCTUnwrap(o.c.claimEnrollmentCleanup())
        XCTAssertEqual(try o.c.enrollmentSessionKeysRequiringRevocation(claim), [])
    }
}
