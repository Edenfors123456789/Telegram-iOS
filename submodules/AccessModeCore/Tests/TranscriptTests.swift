import XCTest
@testable import AccessModeCore

final class TranscriptFixture {
    let vault: VaultFixture
    let store: RestrictedTranscriptStore
    let chat: ChatIdentity
    let now: Int64 = 1_800_000_000

    init() throws {
        vault = try VaultFixture()
        chat = ChatIdentity(account: vault.config.selectedA, peerNamespace: 0, peerID: 50)
        let a = try vault.store.authenticate(pin: "123456")
        try vault.store.setHidden(chat, hidden: true, grant: a, expectedRevision: 1)
        store = try RestrictedTranscriptStore(directory: vault.directory.appendingPathComponent("transcripts"),
            namespace: "test.fork", keyProvider: vault.keys, credentials: vault.store)
    }

    func message(_ id: Int32, namespace: Int32 = 0) -> TranscriptMessageID {
        TranscriptMessageID(chat: chat, namespace: namespace, id: id)
    }

    func b() throws -> AuthenticatedModeGrant { try vault.store.authenticate(pin: "654321") }
    func boundary(_ maximum: Int32 = 100) -> TranscriptBoundary { TranscriptBoundary(maximumMessageIDs: [0: maximum], serverTimestamp: now) }
}

final class TranscriptTests: XCTestCase {
    func testASendIsRecordedByRandomIDBeforeItHasALocalID() throws {
        // The engine learns a message's local id only when it is stored, after the record.
        let f = try TranscriptFixture()
        let b = try f.b()
        let handle = try f.store.begin(chat: f.chat, boundary: f.boundary(), now: f.now, grant: b)
        guard case let .recorded(receipt) = try f.store.recordOutgoing(randomID: 4242, localID: nil, timestamp: f.now, now: f.now, handle: handle, grant: b) else {
            return XCTFail("recorded")
        }
        XCTAssertNil(receipt.localID)
        XCTAssertEqual(try f.store.recordOutgoing(randomID: 4242, localID: nil, timestamp: f.now, now: f.now, handle: handle, grant: b), .alreadyRecorded(receipt))
        try f.store.acknowledge(receipt, serverID: f.message(140))
        let restarted = try RestrictedTranscriptStore(directory: f.vault.directory.appendingPathComponent("transcripts"),
            namespace: "test.fork", keyProvider: f.vault.keys, credentials: f.vault.store)
        let snapshot = try restarted.snapshot(handle: handle, now: f.now, grant: b)
        XCTAssertEqual(snapshot.sendRandomIDs, [4242])
        XCTAssertEqual(snapshot.sendServerIDs, [f.message(140)])
    }

    func testSnapshotNamesWhatTheHistoryRestrictionNeeds() throws {
        let f = try TranscriptFixture()
        let b = try f.b()
        let handle = try f.store.begin(chat: f.chat, boundary: f.boundary(), now: f.now, grant: b)
        let first = f.message(-10, namespace: 1), second = f.message(-11, namespace: 1)
        guard case let .recorded(receipt) = try f.store.recordOutgoing(randomID: 777, localID: first, timestamp: f.now, now: f.now, handle: handle, grant: b) else {
            return XCTFail("recorded")
        }
        _ = try f.store.recordOutgoing(randomID: 778, localID: second, timestamp: f.now, now: f.now, handle: handle, grant: b)
        try f.store.acknowledge(receipt, serverID: f.message(120))
        try f.store.applyDeletion(second)
        try f.store.applyDeletion(f.message(130))
        let snapshot = try f.store.snapshot(handle: handle, now: f.now + 10, grant: b)
        XCTAssertEqual(snapshot.boundary, f.boundary())
        XCTAssertEqual(snapshot.windowStart, f.now + 10 - RestrictedTranscriptStore.window)
        XCTAssertEqual(snapshot.sendRandomIDs, [777], "a deleted send is not shown again")
        XCTAssertEqual(snapshot.sendServerIDs, [f.message(120)])
        XCTAssertEqual(snapshot.deleted, [f.message(130), second], "deletions include a deleted send")
        XCTAssertEqual(try f.store.snapshot(handle: handle, now: f.now - 1_000, grant: b).windowStart, f.now + 10 - RestrictedTranscriptStore.window,
            "a clock moved back does not reopen the window")
        let a = try f.vault.store.authenticate(pin: "123456")
        XCTAssertThrowsError(try f.store.snapshot(handle: handle, now: f.now, grant: a))
    }

    func testBoundaryExcludesOldHistoryAndAOrUnknownOutgoing() throws {
        let f = try TranscriptFixture()
        let b = try f.b()
        let handle = try f.store.begin(chat: f.chat, boundary: f.boundary(), now: f.now, grant: b)
        XCTAssertFalse(try f.store.admit(f.message(99), incoming: true, timestamp: f.now, now: f.now, handle: handle, grant: b))
        XCTAssertFalse(try f.store.admit(f.message(101), incoming: false, timestamp: f.now + 1, now: f.now + 1, handle: handle, grant: b))
        XCTAssertFalse(try f.store.admit(f.message(102), incoming: true, timestamp: f.now - 1, now: f.now + 1, handle: handle, grant: b))
        XCTAssertTrue(try f.store.admit(f.message(103), incoming: true, timestamp: f.now + 1, now: f.now + 1, handle: handle, grant: b))
        XCTAssertEqual(try f.store.visibleMessageIDs(handle: handle, now: f.now + 1, grant: b), [f.message(103)])
        let a = try f.vault.store.authenticate(pin: "123456")
        XCTAssertThrowsError(try f.store.visibleMessageIDs(handle: handle, now: f.now + 1, grant: a))
    }

    func testOfflineBeginDeniesIncomingButDurableOwnSendSurvivesRestartAndAckInA() throws {
        let f = try TranscriptFixture()
        let b = try f.b()
        let handle = try f.store.begin(chat: f.chat, now: f.now, grant: b)
        XCTAssertFalse(try f.store.admit(f.message(101), incoming: true, timestamp: f.now, now: f.now, handle: handle, grant: b))
        let local = f.message(-10, namespace: 1)
        let registration = try f.store.recordOutgoing(randomID: 777, localID: local, timestamp: f.now, now: f.now, handle: handle, grant: b)
        guard case let .recorded(receipt) = registration else { return XCTFail("Initial send must be recorded") }
        XCTAssertEqual(try f.store.visibleMessageIDs(handle: handle, now: f.now, grant: b), [local])
        let restartCredentials = try f.vault.reopen()
        let restarted = try RestrictedTranscriptStore(directory: f.vault.directory.appendingPathComponent("transcripts"),
            namespace: "test.fork", keyProvider: f.vault.keys, credentials: restartCredentials)
        _ = try restartCredentials.authenticate(pin: "123456")
        try restarted.acknowledge(receipt, serverID: f.message(90)) // Below later boundary, but proven B-originated.
        try restarted.acknowledge(receipt, serverID: f.message(90)) // Duplicate acknowledgement is idempotent.
        let newB = try restartCredentials.authenticate(pin: "654321")
        let reopened = try restarted.begin(chat: f.chat, boundary: f.boundary(), now: f.now, grant: newB)
        XCTAssertEqual(try restarted.recordOutgoing(randomID: 777, localID: local, timestamp: f.now, now: f.now,
            handle: reopened, grant: newB), .alreadyRecorded(receipt))
        XCTAssertEqual(try restarted.visibleMessageIDs(handle: reopened, now: f.now, grant: newB), [f.message(90)])
        XCTAssertThrowsError(try restarted.acknowledge(receipt, serverID: f.message(91)))
    }

    func testSevenDayExpiryDoesNotReviveAfterClockRollbackOrRepeatAdmission() throws {
        let f = try TranscriptFixture()
        let b = try f.b()
        let handle = try f.store.begin(chat: f.chat, boundary: f.boundary(), now: f.now, grant: b)
        XCTAssertTrue(try f.store.admit(f.message(101), incoming: true, timestamp: f.now, now: f.now, handle: handle, grant: b))
        let local = f.message(-11, namespace: 1)
        _ = try f.store.recordOutgoing(randomID: 778, localID: local, timestamp: f.now, now: f.now, handle: handle, grant: b)
        XCTAssertEqual(try f.store.visibleMessageIDs(handle: handle, now: f.now + 604_799, grant: b), [f.message(101), local])
        XCTAssertTrue(try f.store.visibleMessageIDs(handle: handle, now: f.now + 604_800, grant: b).isEmpty)
        XCTAssertTrue(try f.store.visibleMessageIDs(handle: handle, now: f.now + 1, grant: b).isEmpty)
        XCTAssertFalse(try f.store.admit(f.message(101), incoming: true, timestamp: f.now, now: f.now + 1, handle: handle, grant: b))
    }

    func testDeleteCannotBeUndoneByStaleHistoryOrLateAck() throws {
        let f = try TranscriptFixture()
        let b = try f.b()
        let handle = try f.store.begin(chat: f.chat, boundary: f.boundary(), now: f.now, grant: b)
        XCTAssertTrue(try f.store.admit(f.message(101), incoming: true, timestamp: f.now, now: f.now, handle: handle, grant: b))
        let local = f.message(-12, namespace: 1)
        guard case let .recorded(receipt) = try f.store.recordOutgoing(randomID: 779, localID: local,
            timestamp: f.now, now: f.now, handle: handle, grant: b) else { return XCTFail() }
        try f.store.applyDeletion(f.message(101))
        try f.store.applyDeletion(local)
        try f.store.acknowledge(receipt, serverID: f.message(102))
        XCTAssertFalse(try f.store.admit(f.message(101), incoming: true, timestamp: f.now, now: f.now, handle: handle, grant: b))
        XCTAssertTrue(try f.store.visibleMessageIDs(handle: handle, now: f.now, grant: b).isEmpty)
    }

    func testUnhideRehideRejectsPriorGenerationEvenWithoutIntermediateOpen() throws {
        let f = try TranscriptFixture()
        let firstB = try f.b()
        let old = try f.store.begin(chat: f.chat, boundary: f.boundary(), now: f.now, grant: firstB)
        XCTAssertTrue(try f.store.admit(f.message(101), incoming: true, timestamp: f.now, now: f.now, handle: old, grant: firstB))
        let a = try f.vault.store.authenticate(pin: "123456")
        try f.vault.store.setHidden(f.chat, hidden: false, grant: a, expectedRevision: 2)
        let againA = try f.vault.store.authenticate(pin: "123456")
        try f.vault.store.setHidden(f.chat, hidden: true, grant: againA, expectedRevision: 3)
        let newB = try f.b()
        XCTAssertThrowsError(try f.store.visibleMessageIDs(handle: old, now: f.now, grant: newB))
        let fresh = try f.store.begin(chat: f.chat, boundary: f.boundary(150), now: f.now, grant: newB)
        XCTAssertNotEqual(old.generation, fresh.generation)
        XCTAssertTrue(try f.store.visibleMessageIDs(handle: fresh, now: f.now, grant: newB).isEmpty)
    }

    func testDiscoveryDoesNotActivateAndUnsupportedBoundaryCannotOpenHistory() throws {
        let f = try TranscriptFixture()
        let b = try f.b()
        let policy = AccessModePolicy(mode: .b, configuration: try f.vault.store.configuration(grant: b))
        XCTAssertFalse(policy.discover(f.chat))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vault.directory.appendingPathComponent("transcripts/access-state.v1.enc").path))
        XCTAssertThrowsError(try f.store.begin(chat: f.chat, boundary: TranscriptBoundary(maximumMessageIDs: [3: 100], serverTimestamp: f.now), now: f.now, grant: b))
        let handle = try f.store.begin(chat: f.chat, boundary: f.boundary(), now: f.now, grant: b)
        XCTAssertFalse(try f.store.admit(f.message(101, namespace: 3), incoming: true, timestamp: f.now, now: f.now, handle: handle, grant: b))
        XCTAssertThrowsError(try f.store.begin(chat: f.chat, boundary: f.boundary(200), now: f.now, grant: b))
        XCTAssertThrowsError(try f.store.recordOutgoing(randomID: 0, localID: f.message(-15, namespace: 1), timestamp: f.now, now: f.now, handle: handle, grant: b))
    }
}
