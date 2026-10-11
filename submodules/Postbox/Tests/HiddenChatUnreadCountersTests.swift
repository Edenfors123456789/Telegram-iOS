import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// While `Postbox.addHiddenChatIds` is held, the unread counters a view reports leave the
/// hidden chats out, the way the chat lists already do: the total and per-group totals
/// (tab badge, folder counters), the archive row and a chat's back-button total. The
/// stored totals stay the real ones; only what views report changes.
final class HiddenChatUnreadCountersTests: XCTestCase {
    private var fixture: PostboxFixture!

    private let tag = PeerSummaryCounterTags(rawValue: 1 << 0)
    private let hiddenChat = MessageHistoryTableFixture.peerId(910)
    private let visibleChat = MessageHistoryTableFixture.peerId(911)
    private let archivedChat = MessageHistoryTableFixture.peerId(912)
    private let namespace = PostboxFixture.messageNamespace
    private let archive = PeerGroupId(rawValue: 1)

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "HiddenChatUnreadCountersTests", counterTags: self.tag)
    }

    override func tearDown() {
        self.fixture.close()
        self.fixture = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func readState(count: Int32, markedUnread: Bool = false) -> PeerReadState {
        return .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 10, count: count, markedUnread: markedUnread)
    }

    /// The hidden chat with five unread, a visible chat with two; optionally the hidden
    /// chat sits in the archive next to an archived visible chat with one.
    private func seed(hiddenGroup: PeerGroupId = .root, hiddenCount: Int32 = 5, hiddenMarkedUnread: Bool = false) {
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: self.hiddenChat, title: "Hidden"), FixturePeer(id: self.visibleChat, title: "Visible"), FixturePeer(id: self.archivedChat, title: "Archived")], update: { _, updated in updated })
            transaction.updatePeerChatListInclusion(self.hiddenChat, inclusion: .ifHasMessagesOrOneOf(groupId: hiddenGroup, pinningIndex: nil, minTimestamp: nil))
            transaction.updatePeerChatListInclusion(self.visibleChat, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
            transaction.updatePeerChatListInclusion(self.archivedChat, inclusion: .ifHasMessagesOrOneOf(groupId: self.archive, pinningIndex: nil, minTimestamp: nil))
            let _ = transaction.addMessages([self.hiddenChat, self.visibleChat, self.archivedChat].enumerated().map { index, peerId in
                MessageHistoryTableFixture.storeMessage(id: MessageId(peerId: peerId, namespace: self.namespace, id: 1), timestamp: 1000 + Int32(index), text: "m", flags: [.Incoming])
            }, location: .Random)
        }
        self.fixture.transaction { transaction in
            transaction.resetIncomingReadStates([
                self.hiddenChat: [self.namespace: self.readState(count: hiddenCount, markedUnread: hiddenMarkedUnread)],
                self.visibleChat: [self.namespace: self.readState(count: 2)],
                self.archivedChat: [self.namespace: self.readState(count: 1)],
            ])
        }
    }

    @discardableResult
    private func hide() -> Disposable {
        let disposable = self.fixture.postbox.addHiddenChatIds(peerIds: [self.hiddenChat])
        self.fixture.transaction { _ in }
        return disposable
    }

    private func observeCounts(_ items: [UnreadMessageCountsItem]) -> PostboxFixture.Recorder<UnreadMessageCountsView> {
        return self.fixture.observe(.unreadCounts(items: items), as: UnreadMessageCountsView.self)
    }

    private func total(_ view: UnreadMessageCountsView?) -> ChatListTotalUnreadState? {
        for entry in view?.entries ?? [] {
            switch entry {
            case let .total(_, state):
                return state
            case let .totalInGroup(_, state):
                return state
            case .peer:
                break
            }
        }
        return nil
    }

    private func counts(_ state: ChatListTotalUnreadState?) -> [Int32] {
        let absolute = state?.absoluteCounters[self.tag]
        let filtered = state?.filteredCounters[self.tag]
        return [absolute?.messageCount ?? 0, absolute?.chatCount ?? 0, filtered?.messageCount ?? 0, filtered?.chatCount ?? 0]
    }

    /// Polls until the recorder's latest value satisfies `condition` (a hidden chat's
    /// changes may produce no new value at all, so a value count cannot be awaited).
    private func eventually<Value>(_ recorder: PostboxFixture.Recorder<Value>, file: StaticString = #file, line: UInt = #line, _ condition: (Value?) -> Bool) {
        let deadline = Date().addingTimeInterval(10.0)
        while !condition(recorder.values.last) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(condition(recorder.values.last), file: file, line: line)
    }

    // MARK: - Totals

    func testWithoutAHiddenSetTheTotalCountsEveryChat() {
        self.seed()
        let recorder = self.observeCounts([.total(nil)])
        XCTAssertEqual(self.counts(self.total(recorder.waitForValues(count: 1).last)), [7, 2, 7, 2])
    }

    func testTheTotalLeavesOutAHiddenChat() {
        self.seed()
        self.hide()
        let recorder = self.observeCounts([.total(nil)])
        XCTAssertEqual(self.counts(self.total(recorder.waitForValues(count: 1).last)), [2, 1, 2, 1])
    }

    func testNewUnreadMessagesInAHiddenChatDoNotMoveTheTotal() {
        self.seed()
        self.hide()
        let recorder = self.observeCounts([.total(nil)])
        recorder.waitForValues(count: 1)
        self.fixture.transaction { transaction in
            transaction.resetIncomingReadStates([
                self.hiddenChat: [self.namespace: self.readState(count: 9)],
                self.visibleChat: [self.namespace: self.readState(count: 3)],
            ])
        }
        self.eventually(recorder) { self.counts(self.total($0)) == [3, 1, 3, 1] }
    }

    func testAHiddenChatMarkedUnreadIsLeftOut() {
        self.seed(hiddenCount: 0, hiddenMarkedUnread: true)
        self.hide()
        let recorder = self.observeCounts([.total(nil)])
        XCTAssertEqual(self.counts(self.total(recorder.waitForValues(count: 1).last)), [2, 1, 2, 1])
    }

    func testTheArchiveTotalLeavesOutAHiddenArchivedChat() {
        self.seed(hiddenGroup: self.archive)
        self.hide()
        let recorder = self.observeCounts([.totalInGroup(self.archive)])
        XCTAssertEqual(self.counts(self.total(recorder.waitForValues(count: 1).last)), [1, 1, 1, 1])
    }

    func testAHiddenChatReportsNoReadState() {
        self.seed()
        self.hide()
        let recorder = self.observeCounts([.peer(id: self.hiddenChat, handleThreads: true), .peer(id: self.visibleChat, handleThreads: true)])
        let entries = recorder.waitForValues(count: 1).last?.entries ?? []
        var states: [PeerId: CombinedPeerReadState?] = [:]
        for case let .peer(peerId, state) in entries {
            states[peerId] = state
        }
        XCTAssertEqual(states.count, 2)
        XCTAssertNil(states[self.hiddenChat] ?? nil, "a hidden chat counts as read")
        XCTAssertEqual(states[self.visibleChat]??.count, 2)
    }

    func testReleasingTheHiddenSetCountsTheChatAgain() {
        self.seed()
        let hidden = self.hide()
        let recorder = self.observeCounts([.total(nil)])
        XCTAssertEqual(self.counts(self.total(recorder.waitForValues(count: 1).last)), [2, 1, 2, 1])
        hidden.dispose()
        self.fixture.transaction { _ in }
        self.eventually(recorder) { self.counts(self.total($0)) == [7, 2, 7, 2] }
    }

    // MARK: - Other surfaces

    func testTheArchiveRowLeavesOutAHiddenChat() {
        self.seed(hiddenGroup: self.archive)
        self.hide()
        let recorder = self.fixture.observe(self.fixture.postbox.tailChatListView(groupId: .root, filterPredicate: nil, count: 10, summaryComponents: ChatListEntrySummaryComponents()) |> map { $0.0 })
        let row = recorder.waitForValues(count: 1).last?.groupEntries.first(where: { $0.groupId == self.archive })
        XCTAssertEqual(row?.unreadState.namespaces[self.namespace]?.all.chatCount, 1)
        XCTAssertEqual(row?.unreadState.namespaces[self.namespace]?.all.messageCount, 1)
        // A new unread message in the hidden chat updates the stored summary; the row must
        // not take it over.
        self.fixture.transaction { transaction in
            transaction.resetIncomingReadStates([
                self.hiddenChat: [self.namespace: self.readState(count: 8)],
                self.archivedChat: [self.namespace: self.readState(count: 4)],
            ])
        }
        self.eventually(recorder) { view in
            let row = view?.groupEntries.first(where: { $0.groupId == self.archive })
            return row?.unreadState.namespaces[self.namespace]?.all.messageCount == 4 && row?.unreadState.namespaces[self.namespace]?.all.chatCount == 1
        }
    }

    func testAChatsBackButtonTotalLeavesOutAHiddenChat() {
        self.seed()
        self.hide()
        let recorder = self.fixture.observeHistory(peerId: self.visibleChat, additionalData: [.totalUnreadState])
        var state: ChatListTotalUnreadState?
        for case let .totalUnreadState(value) in recorder.waitForValues(count: 1).last?.additionalData ?? [] {
            state = value
        }
        // The view reads this once; upstream does not replay it.
        XCTAssertEqual(self.counts(state), [2, 1, 2, 1])
    }
}
