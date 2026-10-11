import XCTest
@testable import AccessModeCore

private final class TranscriptRootUI {
    var active = true
    func controller(_ coordinator: AccessModeCoordinator) throws -> AccessRootPresentation {
        try AccessRootPresentation(coordinator: coordinator, isApplicationActive: { self.active },
            showCover: {}, discardRoot: {}, publishReady: { _ in }, hideCover: {})
    }
}

/// The native layer opens a hidden chat's restricted transcript through the active B root;
/// it never holds a grant itself.
final class RootTranscriptTests: XCTestCase {
    private let now: Int64 = 1_800_000_000

    private func setUp(pin: String) throws -> (f: VaultFixture, store: RestrictedTranscriptStore, controller: AccessRootPresentation, chat: ChatIdentity) {
        let f = try VaultFixture()
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 50)
        try f.store.setHidden(chat, hidden: true, grant: try f.store.authenticate(pin: "123456"), expectedRevision: 1)
        let store = try RestrictedTranscriptStore(directory: f.directory.appendingPathComponent("transcripts"), namespace: "test.fork",
            keyProvider: f.keys, credentials: f.store)
        let coordinator = AccessModeCoordinator(store: f.store), controller = try TranscriptRootUI().controller(coordinator)
        let root = try controller.prepare(coordinator.beginUnlock(pin: pin))
        try controller.complete(root, preparedAccount: f.config.selectedA)
        return (f, store, controller, chat)
    }
    private func boundary() -> TranscriptBoundary { TranscriptBoundary(maximumMessageIDs: [0: 100], serverTimestamp: now) }

    func testBOpensAHiddenChatsTranscriptAndRecordsItsSends() throws {
        let o = try setUp(pin: "654321")
        let (handle, snapshot) = try o.controller.openRestrictedTranscript(o.chat, store: o.store, boundary: boundary(), now: now)
        XCTAssertEqual(snapshot.boundary, boundary())
        XCTAssertEqual(snapshot.sendRandomIDs, [])
        let local = TranscriptMessageID(chat: o.chat, namespace: 1, id: -5)
        guard case .recorded = try o.controller.recordRestrictedSend(handle, store: o.store, randomID: 900, localID: local, timestamp: now, now: now) else {
            return XCTFail("recorded")
        }
        XCTAssertEqual(try o.controller.restrictedTranscriptSnapshot(handle, store: o.store, now: now).sendRandomIDs, [900])
        let (_, reopened) = try o.controller.openRestrictedTranscript(o.chat, store: o.store, boundary: nil, now: now)
        XCTAssertEqual(reopened.boundary, boundary(), "reopening keeps the first boundary")
        let later = TranscriptBoundary(maximumMessageIDs: [0: 180], serverTimestamp: now + 60)
        let (_, refetched) = try o.controller.openRestrictedTranscript(o.chat, store: o.store, boundary: later, now: now + 60)
        XCTAssertEqual(refetched.boundary, boundary(), "a later open with a fresh boundary neither fails nor moves it")
        XCTAssertEqual(refetched.sendRandomIDs, [900])
    }

    func testAOrAnOrdinaryChatHasNoTranscript() throws {
        let a = try setUp(pin: "123456")
        XCTAssertThrowsError(try a.controller.openRestrictedTranscript(a.chat, store: a.store, boundary: boundary(), now: now))
        let b = try setUp(pin: "654321")
        let ordinary = ChatIdentity(account: b.f.config.selectedA, peerNamespace: 0, peerID: 51)
        XCTAssertThrowsError(try b.controller.openRestrictedTranscript(ordinary, store: b.store, boundary: boundary(), now: now))
    }

    func testASendRecorderWorksOffTheMainThreadUntilTheRootGoes() throws {
        // Sends are recorded where Postbox stores them, on its queue.
        let o = try setUp(pin: "654321")
        let (handle, _) = try o.controller.openRestrictedTranscript(o.chat, store: o.store, boundary: boundary(), now: now)
        let recorder = try o.controller.restrictedSendRecorder(handle, store: o.store)
        let done = expectation(description: "recorded off main")
        var registration: BSendRegistration?
        DispatchQueue.global().async {
            registration = try? recorder.record(randomID: 31, timestamp: self.now, now: self.now)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        guard case .recorded? = registration else { return XCTFail("recorded") }
        XCTAssertEqual(try o.controller.restrictedTranscriptSnapshot(handle, store: o.store, now: now).sendRandomIDs, [31])
        try o.controller.lock()
        XCTAssertThrowsError(try recorder.record(randomID: 32, timestamp: now, now: now))
    }

    func testALockedRootCannotUseAnEarlierHandle() throws {
        let o = try setUp(pin: "654321")
        let (handle, _) = try o.controller.openRestrictedTranscript(o.chat, store: o.store, boundary: boundary(), now: now)
        try o.controller.lock()
        XCTAssertThrowsError(try o.controller.restrictedTranscriptSnapshot(handle, store: o.store, now: now))
        XCTAssertThrowsError(try o.controller.recordRestrictedSend(handle, store: o.store, randomID: 901,
            localID: TranscriptMessageID(chat: o.chat, namespace: 1, id: -6), timestamp: now, now: now))
    }
}
