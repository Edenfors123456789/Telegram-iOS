import Foundation
import XCTest
import Postbox
@testable import TelegramCore

/// Search results built outside Postbox (server results, recents, top peers) leave out the
/// chats Dual PIN's restricted mode keeps out of lists.
final class HiddenChatSearchResultsTests: XCTestCase {
    private let hiddenUser = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(31))
    private let visibleUser = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(32))

    private func user(_ id: PeerId) -> TelegramUser {
        return TelegramUser(id: id, accessHash: nil, firstName: "U\(id.id._internalGetInt64Value())", lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
    }

    func testMessagesOfHiddenChatsLeaveTheResultAndItsCount() {
        let hiddenMessage = SparseFixtures.message(self.hiddenUser, 1, timestamp: 10)
        let visibleMessage = SparseFixtures.message(self.visibleUser, 2, timestamp: 20)
        let state = CombinedPeerReadState(states: [(Namespaces.Message.Cloud, .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 2, count: 1, markedUnread: false))])
        let result = SearchMessagesResult(messages: [visibleMessage, hiddenMessage], readStates: [self.hiddenUser: state, self.visibleUser: state], threadInfo: [:], totalCount: 40, completed: false)
        let filtered = excludingChatsHiddenFromLists(result, [self.hiddenUser])
        XCTAssertEqual(filtered.messages.map(\.id), [visibleMessage.id])
        XCTAssertEqual(Set(filtered.readStates.keys), [self.visibleUser])
        XCTAssertEqual(filtered.totalCount, 39, "the count does not reveal the hidden match")
        XCTAssertFalse(filtered.completed)
    }

    func testStorageUsageLeavesOutHiddenChatsAndTheirShare() {
        // Storage usage names chats and lists their cached media.
        let hiddenMessage = EngineMessage.Id(peerId: self.hiddenUser, namespace: Namespaces.Message.Cloud, id: 1)
        let visibleMessage = EngineMessage.Id(peerId: self.visibleUser, namespace: Namespaces.Message.Cloud, id: 2)
        let total = StorageUsageStats(categories: [.photos: StorageUsageStats.CategoryData(size: 300, messages: [hiddenMessage: 100, visibleMessage: 150])])
        let stats = AllStorageUsageStats(deviceAvailableSpace: 1000, deviceFreeSpace: 500, totalStats: total, peers: [
            self.hiddenUser: AllStorageUsageStats.PeerStats(peer: EnginePeer(self.user(self.hiddenUser)), stats: StorageUsageStats(categories: [:])),
            self.visibleUser: AllStorageUsageStats.PeerStats(peer: EnginePeer(self.user(self.visibleUser)), stats: StorageUsageStats(categories: [:])),
        ])
        let filtered = excludingChatsHiddenFromLists(stats, [self.hiddenUser])
        XCTAssertEqual(Set(filtered.peers.keys), [self.visibleUser])
        XCTAssertEqual(filtered.totalStats.categories[.photos]?.messages.keys.map { $0 }, [visibleMessage])
        XCTAssertEqual(filtered.totalStats.categories[.photos]?.size, 200)
        XCTAssertEqual(filtered.deviceFreeSpace, 500)
    }

    func testANothingHiddenResultIsUnchanged() {
        let message = SparseFixtures.message(self.visibleUser, 2, timestamp: 20)
        let result = SearchMessagesResult(messages: [message], readStates: [:], threadInfo: [:], totalCount: 1, completed: true)
        XCTAssertEqual(excludingChatsHiddenFromLists(result, [self.hiddenUser]), result)
        XCTAssertEqual(excludingChatsHiddenFromLists(result, [self.hiddenUser]).totalCount, 1)
    }

    func testRecentAndTopPeersLeaveOutHiddenChats() {
        let recent = excludingChatsHiddenFromLists(.peers([self.user(self.hiddenUser), self.user(self.visibleUser)]), [self.hiddenUser])
        guard case let .peers(peers) = recent else {
            return XCTFail("still a peer list")
        }
        XCTAssertEqual(peers.map(\.id), [self.visibleUser])
        guard case .disabled = excludingChatsHiddenFromLists(RecentPeers.disabled, [self.hiddenUser]) else {
            return XCTFail("disabled stays disabled")
        }
        let searched = [self.hiddenUser, self.visibleUser].map { id in
            RecentlySearchedPeer(peer: RenderedPeer(peer: self.user(id)), presence: nil, notificationSettings: nil, unreadCount: 3, subpeerSummary: nil)
        }
        XCTAssertEqual(excludingChatsHiddenFromLists(searched, [self.hiddenUser]).map(\.peer.peerId), [self.visibleUser])
    }

    func testOnlyTheAccountsOwnPeerMatchesAreFiltered() {
        let found = [self.hiddenUser, self.visibleUser].map { FoundPeer(peer: EnginePeer(self.user($0)), subscribers: nil) }
        XCTAssertEqual(excludingChatsHiddenFromLists(myResults: found, [self.hiddenUser]).map(\.peer.id), [self.visibleUser])
    }
}
