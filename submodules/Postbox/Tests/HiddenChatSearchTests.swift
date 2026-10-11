import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// While `Postbox.addHiddenChatIds` is held, local search finds neither a hidden chat nor
/// its messages, as the chat lists already leave it out. A hidden chat with a contact is
/// still found as that contact (a row without history, as in the contact list); opening it
/// is the explicit route that leads to the restricted transcript.
final class HiddenChatSearchTests: XCTestCase {
    private var fixture: PostboxFixture!

    private let hiddenChat = MessageHistoryTableFixture.peerId(920)
    private let visibleChat = MessageHistoryTableFixture.peerId(921)
    private let hiddenContact = MessageHistoryTableFixture.peerId(922)
    private let namespace = PostboxFixture.messageNamespace

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "HiddenChatSearchTests", textIndexNamespaces: [self.hiddenChat.namespace])
    }

    override func tearDown() {
        self.fixture.close()
        self.fixture = nil
        super.tearDown()
    }

    private func seed() {
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: self.hiddenChat, title: "Alpha Hidden"), FixturePeer(id: self.visibleChat, title: "Alpha Visible"), FixturePeer(id: self.hiddenContact, title: "Alpha Contact")], update: { _, updated in updated })
            for peerId in [self.hiddenChat, self.visibleChat, self.hiddenContact] {
                transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
            }
            transaction.replaceContactPeerIds([self.hiddenContact])
            let _ = transaction.addMessages([self.hiddenChat, self.visibleChat, self.hiddenContact].enumerated().map { index, peerId in
                MessageHistoryTableFixture.storeMessage(id: MessageId(peerId: peerId, namespace: self.namespace, id: 1), timestamp: 1000 + Int32(index), text: "bravo words", flags: [.Incoming])
            }, location: .Random)
        }
    }

    @discardableResult
    private func hide() -> Disposable {
        let disposable = self.fixture.postbox.addHiddenChatIds(peerIds: [self.hiddenChat, self.hiddenContact])
        self.fixture.transaction { _ in }
        return disposable
    }

    private func peerSearch(_ query: String) -> [PeerId] {
        return self.fixture.transaction { transaction in
            transaction.searchPeers(query: query, predicate: nil).map(\.peerId)
        } ?? []
    }

    private func messageSearch(_ query: String) -> [PeerId] {
        return self.fixture.transaction { transaction in
            transaction.searchMessages(peerId: nil, query: query, tags: nil).map(\.id.peerId)
        } ?? []
    }

    func testWithoutAHiddenSetSearchFindsEveryChat() {
        self.seed()
        XCTAssertEqual(Set(self.peerSearch("Alpha")), [self.hiddenChat, self.visibleChat, self.hiddenContact])
        XCTAssertEqual(Set(self.messageSearch("bravo")), [self.hiddenChat, self.visibleChat, self.hiddenContact])
    }

    func testPeerSearchSkipsHiddenChatsButFindsAHiddenContactAsAContact() {
        self.seed()
        self.hide()
        XCTAssertEqual(self.peerSearch("Alpha"), [self.visibleChat, self.hiddenContact], "chats first, then contacts")
    }

    func testPeerSearchSignalSkipsHiddenChats() {
        self.seed()
        self.hide()
        let recorder = self.fixture.observe(self.fixture.postbox.searchPeers(query: "Alpha", predicate: nil))
        XCTAssertEqual(recorder.waitForValues(count: 1).last?.map(\.peerId), [self.visibleChat, self.hiddenContact])
    }

    func testMessageSearchSkipsHiddenChats() {
        self.seed()
        self.hide()
        XCTAssertEqual(self.messageSearch("bravo"), [self.visibleChat])
    }

    func testTheHiddenSetSnapshotFollowsRegistration() {
        XCTAssertEqual(self.fixture.observe(self.fixture.postbox.chatIdsHiddenFromLists()).waitForValues(count: 1).last, [])
        let hidden = self.hide()
        XCTAssertEqual(self.fixture.observe(self.fixture.postbox.chatIdsHiddenFromLists()).waitForValues(count: 1).last, [self.hiddenChat, self.hiddenContact])
        hidden.dispose()
        XCTAssertEqual(self.fixture.observe(self.fixture.postbox.chatIdsHiddenFromLists()).waitForValues(count: 1).last, [])
    }

    func testReleasingTheHiddenSetFindsThemAgain() {
        self.seed()
        let hidden = self.hide()
        XCTAssertEqual(self.peerSearch("Alpha"), [self.visibleChat, self.hiddenContact])
        hidden.dispose()
        self.fixture.transaction { _ in }
        XCTAssertEqual(Set(self.peerSearch("Alpha")), [self.hiddenChat, self.visibleChat, self.hiddenContact])
    }
}
