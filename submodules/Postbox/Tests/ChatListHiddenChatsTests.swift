import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// `Postbox.addHiddenChatIds` keeps chats out of every chat list view while its
/// disposable is held (Dual PIN's restricted mode relies on it). A hidden chat must
/// stay out on every path that puts an entry into a view, not only when the view is
/// first filled: new messages, pins, a folder's own pinned chats, the archive preview.
final class ChatListHiddenChatsTests: XCTestCase {
    private var fixture: PostboxFixture!

    private let hiddenChat = MessageHistoryTableFixture.peerId(900)
    private let visibleChat = MessageHistoryTableFixture.peerId(901)
    private let namespace = PostboxFixture.messageNamespace
    private let archive = PeerGroupId(rawValue: 1)

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "ChatListHiddenChatsTests")
    }

    override func tearDown() {
        self.fixture.close()
        self.fixture = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func message(peerId: PeerId, id: Int32, timestamp: Int32) -> StoreMessage {
        return MessageHistoryTableFixture.storeMessage(id: MessageId(peerId: peerId, namespace: self.namespace, id: id), timestamp: timestamp, text: "m\(id)", flags: [.Incoming])
    }

    private func seed(hiddenGroup: PeerGroupId = .root, pinHidden: Bool = false) {
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: self.hiddenChat, title: "Hidden"), FixturePeer(id: self.visibleChat, title: "Visible")], update: { _, updated in updated })
            transaction.updatePeerChatListInclusion(self.hiddenChat, inclusion: .ifHasMessagesOrOneOf(groupId: hiddenGroup, pinningIndex: nil, minTimestamp: nil))
            transaction.updatePeerChatListInclusion(self.visibleChat, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
            let _ = transaction.addMessages([
                self.message(peerId: self.visibleChat, id: 1, timestamp: 1000),
                self.message(peerId: self.hiddenChat, id: 1, timestamp: 2000),
            ], location: .Random)
            if pinHidden {
                transaction.setPinnedItemIds(groupId: hiddenGroup, itemIds: [.peer(self.hiddenChat)])
            }
        }
    }

    /// Registers the hidden set and waits until it is in place for later views.
    @discardableResult
    private func hide() -> Disposable {
        let disposable = self.fixture.postbox.addHiddenChatIds(peerIds: [self.hiddenChat])
        self.fixture.transaction { _ in }
        return disposable
    }

    /// A new message in both chats in one transaction: the view must report the
    /// visible chat's update, so there is always a next value to inspect.
    private func receiveInBothChats(id: Int32, timestamp: Int32) {
        self.fixture.transaction { transaction in
            let _ = transaction.addMessages([
                self.message(peerId: self.hiddenChat, id: id, timestamp: timestamp),
                self.message(peerId: self.visibleChat, id: id, timestamp: timestamp + 1),
            ], location: .Random)
        }
    }

    private func observe(groupId: PeerGroupId = .root, predicate: ChatListFilterPredicate? = nil) -> PostboxFixture.Recorder<ChatListView> {
        return self.fixture.observe(self.fixture.postbox.tailChatListView(groupId: groupId, filterPredicate: predicate, count: 10, summaryComponents: ChatListEntrySummaryComponents()) |> map { $0.0 })
    }

    private func peers(in view: ChatListView?) -> [PeerId] {
        return (view?.entries ?? []).compactMap { entry -> PeerId? in
            if case let .MessageEntry(data) = entry {
                return data.index.messageIndex.id.peerId
            }
            return nil
        }
    }

    private func newestMessageId(of peerId: PeerId, in view: ChatListView?) -> Int32? {
        for entry in view?.entries ?? [] {
            if case let .MessageEntry(data) = entry, data.index.messageIndex.id.peerId == peerId {
                return data.index.messageIndex.id.id
            }
        }
        return nil
    }

    private func folder(pinned: [PeerId] = []) -> ChatListFilterPredicate {
        return ChatListFilterPredicate(includePeerIds: [], excludePeerIds: [], pinnedPeerIds: pinned, messageTagSummary: nil, includeAdditionalPeerGroupIds: [], include: { _, _, _, _, _ in true })
    }

    // MARK: - Main list

    func testAHiddenChatIsAbsentFromTheMainList() {
        self.seed()
        self.hide()
        let recorder = self.observe()
        XCTAssertEqual(self.peers(in: recorder.waitForValues(count: 1).last), [self.visibleChat])
    }

    func testANewMessageDoesNotBringAHiddenChatBack() {
        self.seed()
        self.hide()
        let recorder = self.observe()
        recorder.waitForValues(count: 1)
        self.receiveInBothChats(id: 2, timestamp: 3000)
        let view = recorder.waitForValues(count: 2).last
        XCTAssertEqual(self.newestMessageId(of: self.visibleChat, in: view), 2, "the view did take the transaction")
        XCTAssertEqual(self.peers(in: view), [self.visibleChat])
    }

    func testAPinnedHiddenChatStaysHiddenAfterANewMessage() {
        self.seed(pinHidden: true)
        self.hide()
        let recorder = self.observe()
        XCTAssertEqual(self.peers(in: recorder.waitForValues(count: 1).last), [self.visibleChat])
        self.receiveInBothChats(id: 2, timestamp: 3000)
        let view = recorder.waitForValues(count: 2).last
        XCTAssertEqual(self.newestMessageId(of: self.visibleChat, in: view), 2)
        XCTAssertEqual(self.peers(in: view), [self.visibleChat])
    }

    func testPinningAHiddenChatDoesNotShowIt() {
        self.seed()
        self.hide()
        let recorder = self.observe()
        recorder.waitForValues(count: 1)
        self.fixture.transaction { transaction in
            transaction.setPinnedItemIds(groupId: .root, itemIds: [.peer(self.hiddenChat)])
            let _ = transaction.addMessages([self.message(peerId: self.visibleChat, id: 2, timestamp: 3000)], location: .Random)
        }
        let view = recorder.waitForValues(count: 2).last
        XCTAssertEqual(self.newestMessageId(of: self.visibleChat, in: view), 2)
        XCTAssertEqual(self.peers(in: view), [self.visibleChat])
    }

    // MARK: - Folders

    func testAFolderNeverShowsAHiddenChat() {
        self.seed()
        self.hide()
        let recorder = self.observe(predicate: self.folder())
        XCTAssertEqual(self.peers(in: recorder.waitForValues(count: 1).last), [self.visibleChat])
        self.receiveInBothChats(id: 2, timestamp: 3000)
        let view = recorder.waitForValues(count: 2).last
        XCTAssertEqual(self.newestMessageId(of: self.visibleChat, in: view), 2)
        XCTAssertEqual(self.peers(in: view), [self.visibleChat])
    }

    func testAFolderDoesNotShowAHiddenChatItPins() {
        self.seed()
        self.hide()
        let recorder = self.observe(predicate: self.folder(pinned: [self.hiddenChat]))
        XCTAssertEqual(self.peers(in: recorder.waitForValues(count: 1).last), [self.visibleChat])
        self.receiveInBothChats(id: 2, timestamp: 3000)
        let view = recorder.waitForValues(count: 2).last
        XCTAssertEqual(self.newestMessageId(of: self.visibleChat, in: view), 2)
        XCTAssertEqual(self.peers(in: view), [self.visibleChat])
    }

    func testAFolderReevaluatingAHiddenChatDoesNotReaddIt() {
        // A chat's cached data changing makes a folder re-run its predicate and
        // re-add the chat from the table if it now passes.
        final class Switch { var includesHidden = false }
        let filter = Switch(), hiddenChat = self.hiddenChat
        let predicate = ChatListFilterPredicate(includePeerIds: [], excludePeerIds: [], pinnedPeerIds: [], messageTagSummary: nil, includeAdditionalPeerGroupIds: [], include: { peer, _, _, _, _ in
            return peer.id != hiddenChat || filter.includesHidden
        })
        // A newer visible chat puts the hidden one between two rows, where a re-add
        // is inserted directly instead of reloading the space from the table.
        let newerChat = MessageHistoryTableFixture.peerId(902)
        self.seed()
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: newerChat, title: "Newer")], update: { _, updated in updated })
            transaction.updatePeerChatListInclusion(newerChat, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
            let _ = transaction.addMessages([self.message(peerId: newerChat, id: 1, timestamp: 2500)], location: .Random)
        }
        self.hide()
        let recorder = self.observe(predicate: predicate)
        XCTAssertEqual(self.peers(in: recorder.waitForValues(count: 1).last), [self.visibleChat, newerChat])
        filter.includesHidden = true
        self.fixture.transaction { transaction in
            transaction.updatePeerCachedData(peerIds: [self.hiddenChat], update: { _, _ in FixtureCachedPeerData(peerIds: []) })
            let _ = transaction.addMessages([self.message(peerId: newerChat, id: 2, timestamp: 2600)], location: .Random)
        }
        let view = recorder.waitForValues(count: 2).last
        XCTAssertEqual(self.newestMessageId(of: newerChat, in: view), 2)
        XCTAssertEqual(self.peers(in: view), [self.visibleChat, newerChat])
    }

    // MARK: - Archive

    func testTheArchivePreviewSkipsAHiddenChat() {
        self.seed(hiddenGroup: self.archive)
        self.hide()
        let recorder = self.observe()
        let initial = recorder.waitForValues(count: 1).last
        XCTAssertFalse((initial?.groupEntries ?? []).contains(where: { $0.renderedPeers.contains(where: { $0.peer.peerId == self.hiddenChat }) }))
        self.receiveInBothChats(id: 2, timestamp: 3000)
        let view = recorder.waitForValues(count: 2).last
        XCTAssertFalse((view?.groupEntries ?? []).contains(where: { $0.renderedPeers.contains(where: { $0.peer.peerId == self.hiddenChat }) }))
        let archived = self.observe(groupId: self.archive)
        XCTAssertEqual(self.peers(in: archived.waitForValues(count: 1).last), [], "the archive itself does not list it either")
    }

    // MARK: - Lifetime

    func testReleasingTheHiddenSetShowsTheChatAgain() {
        self.seed()
        let hidden = self.hide()
        let recorder = self.observe()
        XCTAssertEqual(self.peers(in: recorder.waitForValues(count: 1).last), [self.visibleChat])
        hidden.dispose()
        // Removal is applied on the Postbox queue outside a transaction; the next
        // transaction makes the views notice it.
        self.fixture.transaction { _ in }
        self.receiveInBothChats(id: 2, timestamp: 3000)
        let deadline = Date().addingTimeInterval(10.0)
        while Set(self.peers(in: recorder.values.last)) != [self.visibleChat, self.hiddenChat] && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(Set(self.peers(in: recorder.values.last)), [self.visibleChat, self.hiddenChat])
    }
}
