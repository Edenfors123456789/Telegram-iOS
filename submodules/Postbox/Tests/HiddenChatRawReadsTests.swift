import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// While `Postbox.addHiddenChatIds` is held, the raw reads that do not go through a chat
/// list view leave the hidden chats out too: the unread peer ids (next unread channel,
/// mark all as read), the relative unread index, the Saved Messages sub-chat list and
/// the sub-chat search. Without a hold every one of them returns the chat as before.
final class HiddenChatRawReadsTests: XCTestCase {
    private var fixture: PostboxFixture!

    private let hiddenChat = MessageHistoryTableFixture.peerId(930)
    private let visibleChat = MessageHistoryTableFixture.peerId(931)
    private let savedContainer = MessageHistoryTableFixture.peerId(932)
    private let namespace = PostboxFixture.messageNamespace

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "HiddenChatRawReadsTests")
    }

    override func tearDown() {
        self.fixture.close()
        self.fixture = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func readState(count: Int32) -> PeerReadState {
        return .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 10, count: count, markedUnread: false)
    }

    /// Two unread chats; the hidden one is the newest, so it is the first the walk meets.
    private func seedUnread() {
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: self.hiddenChat, title: "Hidden"), FixturePeer(id: self.visibleChat, title: "Visible")], update: { _, updated in updated })
            transaction.updatePeerChatListInclusion(self.hiddenChat, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
            transaction.updatePeerChatListInclusion(self.visibleChat, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
            let _ = transaction.addMessages([
                MessageHistoryTableFixture.storeMessage(id: MessageId(peerId: self.visibleChat, namespace: self.namespace, id: 1), timestamp: 1000, text: "m", flags: [.Incoming]),
                MessageHistoryTableFixture.storeMessage(id: MessageId(peerId: self.hiddenChat, namespace: self.namespace, id: 1), timestamp: 2000, text: "m", flags: [.Incoming]),
            ], location: .Random)
        }
        self.fixture.transaction { transaction in
            transaction.resetIncomingReadStates([
                self.hiddenChat: [self.namespace: self.readState(count: 3)],
                self.visibleChat: [self.namespace: self.readState(count: 2)],
            ])
        }
    }

    /// Saved Messages with two sub-chats, one per source peer (the thread id is the
    /// source peer's id), and a valid index boundary so the view is not loading.
    private func seedSavedMessages() {
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: self.savedContainer, title: "Saved"), FixturePeer(id: self.hiddenChat, title: "Chat Hidden"), FixturePeer(id: self.visibleChat, title: "Chat Visible")], update: { _, updated in updated })
            let threadIds = [self.hiddenChat.toInt64(), self.visibleChat.toInt64()]
            var messages: [StoreMessage] = []
            for (index, threadId) in threadIds.enumerated() {
                messages.append(StoreMessage(id: MessageId(peerId: self.savedContainer, namespace: self.namespace, id: Int32(index) + 1), customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: threadId, timestamp: 1000 + Int32(index), flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: nil, text: "m", attributes: [], media: []))
            }
            let _ = transaction.addMessages(messages, location: .Random)
            for threadId in threadIds {
                transaction.setMessageHistoryThreadInfo(peerId: self.savedContainer, threadId: threadId, info: StoredMessageHistoryThreadInfo(data: CodableEntry(data: Data()), summary: StoredMessageHistoryThreadInfo.Summary(totalUnreadCount: 0, isMarkedUnread: false, mutedUntil: nil, maxOutgoingReadId: 0)))
            }
            transaction.setPeerThreadCombinedState(peerId: self.savedContainer, state: StoredPeerThreadCombinedState(data: CodableEntry(data: Data()), validIndexBoundary: StoredPeerThreadCombinedState.Index(timestamp: 0, threadId: 0, messageId: 1)))
        }
    }

    @discardableResult
    private func hide() -> Disposable {
        let disposable = self.fixture.postbox.addHiddenChatIds(peerIds: [self.hiddenChat])
        self.fixture.transaction { _ in }
        return disposable
    }

    private func unreadPeerIds(stopOnFirstMatch: Bool) -> [PeerId] {
        return self.fixture.transaction { transaction in
            transaction.getUnreadChatListPeerIds(groupId: .root, filterPredicate: nil, additionalFilter: nil, stopOnFirstMatch: stopOnFirstMatch)
        } ?? []
    }

    private func relativeUnreadPeerId() -> PeerId? {
        return self.fixture.transaction { transaction in
            transaction.getRelativeUnreadChatListIndex(filtered: false, position: .later(than: nil), groupId: .root)?.messageIndex.id.peerId
        } ?? nil
    }

    private func savedThreadIds(_ view: MessageHistorySavedMessagesIndexView?) -> Set<Int64> {
        return Set((view?.items ?? []).map(\.id))
    }

    private func searchSubPeers() -> [PeerId] {
        return self.fixture.transaction { transaction in
            transaction.searchSubPeers(peerId: self.savedContainer, query: "chat", indexNameMapping: [:]).map(\.id)
        } ?? []
    }

    // MARK: - Unread peer ids

    func testWithoutAHoldTheUnreadPeerIdsIncludeEveryChat() {
        self.seedUnread()
        XCTAssertEqual(self.unreadPeerIds(stopOnFirstMatch: false), [self.hiddenChat, self.visibleChat])
        XCTAssertEqual(self.unreadPeerIds(stopOnFirstMatch: true), [self.hiddenChat])
    }

    func testTheUnreadPeerIdsLeaveOutAHiddenChat() {
        self.seedUnread()
        self.hide()
        XCTAssertEqual(self.unreadPeerIds(stopOnFirstMatch: false), [self.visibleChat])
    }

    func testStopOnFirstMatchReturnsTheVisibleChatBehindAHiddenOne() {
        self.seedUnread()
        self.hide()
        XCTAssertEqual(self.unreadPeerIds(stopOnFirstMatch: true), [self.visibleChat])
    }

    // MARK: - Relative unread index

    func testWithoutAHoldTheRelativeUnreadIndexLandsOnTheNewestChat() {
        self.seedUnread()
        XCTAssertEqual(self.relativeUnreadPeerId(), self.hiddenChat)
    }

    func testTheRelativeUnreadIndexSkipsAHiddenChat() {
        self.seedUnread()
        self.hide()
        XCTAssertEqual(self.relativeUnreadPeerId(), self.visibleChat)
    }

    // MARK: - Saved Messages sub-chats

    func testWithoutAHoldTheSavedMessagesIndexListsEverySubChat() {
        self.seedSavedMessages()
        let recorder = self.fixture.observe(.savedMessagesIndex(peerId: self.savedContainer), as: MessageHistorySavedMessagesIndexView.self)
        XCTAssertEqual(self.savedThreadIds(recorder.waitForValues(count: 1).last), [self.hiddenChat.toInt64(), self.visibleChat.toInt64()])
    }

    func testTheSavedMessagesIndexHasNoItemForAHiddenSourcePeer() {
        self.seedSavedMessages()
        self.hide()
        let recorder = self.fixture.observe(.savedMessagesIndex(peerId: self.savedContainer), as: MessageHistorySavedMessagesIndexView.self)
        XCTAssertEqual(self.savedThreadIds(recorder.waitForValues(count: 1).last), [self.visibleChat.toInt64()])
    }

    func testTheLiveSavedMessagesIndexFollowsTheHold() {
        self.seedSavedMessages()
        let recorder = self.fixture.observe(.savedMessagesIndex(peerId: self.savedContainer), as: MessageHistorySavedMessagesIndexView.self)
        XCTAssertEqual(self.savedThreadIds(recorder.waitForValues(count: 1).last), [self.hiddenChat.toInt64(), self.visibleChat.toInt64()])

        let hold = self.hide()
        self.eventually(recorder) { self.savedThreadIds($0) == [self.visibleChat.toInt64()] }

        hold.dispose()
        self.fixture.transaction { _ in }
        self.eventually(recorder) { self.savedThreadIds($0) == [self.hiddenChat.toInt64(), self.visibleChat.toInt64()] }
    }

    // MARK: - Sub-chat search

    func testWithoutAHoldSearchSubPeersFindsEveryChat() {
        self.seedSavedMessages()
        XCTAssertEqual(Set(self.searchSubPeers()), [self.hiddenChat, self.visibleChat])
    }

    func testSearchSubPeersOmitsAHiddenPeer() {
        self.seedSavedMessages()
        self.hide()
        XCTAssertEqual(self.searchSubPeers(), [self.visibleChat])
    }

    /// Polls until the recorder's latest value satisfies `condition`: a hold changing
    /// produces its next value on the Postbox queue, not inside the call that caused it.
    private func eventually<Value>(_ recorder: PostboxFixture.Recorder<Value>, file: StaticString = #file, line: UInt = #line, _ condition: (Value?) -> Bool) {
        let deadline = Date().addingTimeInterval(10.0)
        while !condition(recorder.values.last) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(condition(recorder.values.last), file: file, line: line)
    }
}
