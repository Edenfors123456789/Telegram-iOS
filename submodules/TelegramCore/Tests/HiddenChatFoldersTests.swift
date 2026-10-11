import Foundation
import XCTest
import Postbox
@testable import TelegramCore

/// A folder edited while chats are hidden from lists (Dual PIN's restricted mode) keeps the
/// hidden chats it already had: the editor never showed them, so their absence is no decision.
final class HiddenChatFoldersTests: XCTestCase {
    private func peer(_ id: Int64) -> PeerId {
        return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(id))
    }

    private func folder(_ id: Int32 = 2, include: [PeerId], pinned: [PeerId] = [], exclude: [PeerId] = []) -> ChatListFilter {
        let data = ChatListFilterData(isShared: false, hasSharedLinks: false, categories: [], excludeMuted: false, excludeRead: false, excludeArchived: false,
            includePeers: ChatListFilterIncludePeers(peers: include, pinnedPeers: pinned), excludePeers: exclude, color: nil)
        return .filter(id: id, title: ChatFolderTitle(text: "F", entities: [], enableAnimations: true), emoticon: nil, data: data)
    }

    private func data(_ filter: ChatListFilter?) -> ChatListFilterData? {
        if case let .filter(_, _, _, data) = filter {
            return data
        }
        return nil
    }

    func testAnEditKeepsTheHiddenMembersItDidNotShow() {
        let hidden = self.peer(1), visible = self.peer(2), added = self.peer(3)
        let previous = [self.folder(include: [hidden, visible], pinned: [hidden], exclude: [self.peer(9)])]
        // The editor saw only the visible chat; the user added one and cleared the exclusions.
        let edited = [self.folder(include: [added, visible], exclude: [])]
        let result = self.data(preservingChatsHiddenFromLists(previous: previous, updated: edited, hidden: [hidden, self.peer(9)]).first)
        XCTAssertEqual(Set(result?.includePeers.peers ?? []), [hidden, visible, added])
        XCTAssertEqual(result?.includePeers.pinnedPeers, [hidden], "a hidden pin stays pinned")
        XCTAssertEqual(result?.excludePeers, [self.peer(9)], "a hidden exclusion stays too")
    }

    func testVisibleChangesAndOtherFoldersAreUntouched() {
        let visible = self.peer(2)
        let previous = [self.folder(include: [visible]), self.folder(3, include: [self.peer(4)])]
        let edited = [self.folder(include: []), self.folder(3, include: [self.peer(4)])]
        XCTAssertEqual(preservingChatsHiddenFromLists(previous: previous, updated: edited, hidden: [self.peer(1)]), edited)
        XCTAssertEqual(preservingChatsHiddenFromLists(previous: previous, updated: edited, hidden: []), edited)
    }

    func testANewOrDeletedFolderIsLeftAsEdited() {
        let previous = [self.folder(include: [self.peer(1)])]
        XCTAssertEqual(preservingChatsHiddenFromLists(previous: previous, updated: [], hidden: [self.peer(1)]), [], "deleting a folder is explicit")
        let created = [self.folder(include: [self.peer(1)]), self.folder(5, include: [self.peer(6)])]
        XCTAssertEqual(preservingChatsHiddenFromLists(previous: previous, updated: created, hidden: [self.peer(1)]), created)
    }
}
