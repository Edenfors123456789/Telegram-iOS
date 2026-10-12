import Foundation
import Postbox
import SwiftSignalKit

// Dual PIN restricted mode keeps some chats out of every list (`Postbox.addHiddenChatIds`).
// Search results built outside Postbox (server results, recents, top peers) drop them here,
// so every screen that searches — chat list, share sheet, forwarding — sees the same.

/// `signal`'s values filtered by the chats currently hidden from lists. The set is read once
/// per subscription: it only changes with the mode root, which rebuilds its searches.
func withChatsHiddenFromLists<T>(_ postbox: Postbox, _ signal: Signal<T, NoError>, _ filter: @escaping (T, Set<PeerId>) -> T) -> Signal<T, NoError> {
    return combineLatest(signal, postbox.chatIdsHiddenFromLists())
    |> map { value, hidden -> T in
        return hidden.isEmpty ? value : filter(value, hidden)
    }
}

/// Messages of hidden chats leave the result and its count; their read states and thread
/// data go with them.
func excludingChatsHiddenFromLists(_ result: SearchMessagesResult, _ hidden: Set<PeerId>) -> SearchMessagesResult {
    let messages = result.messages.filter { !hidden.contains($0.id.peerId) }
    if messages.count == result.messages.count && !result.readStates.keys.contains(where: hidden.contains) {
        return result
    }
    return SearchMessagesResult(
        messages: messages,
        readStates: result.readStates.filter { !hidden.contains($0.key) },
        threadInfo: result.threadInfo.filter { !hidden.contains($0.key.peerId) },
        totalCount: max(0, result.totalCount - Int32(result.messages.count - messages.count)),
        completed: result.completed
    )
}

func excludingChatsHiddenFromLists(_ peers: [RecentlySearchedPeer], _ hidden: Set<PeerId>) -> [RecentlySearchedPeer] {
    return peers.filter { !hidden.contains($0.peer.peerId) }
}

func excludingChatsHiddenFromLists(_ recent: RecentPeers, _ hidden: Set<PeerId>) -> RecentPeers {
    switch recent {
    case let .peers(peers):
        return .peers(peers.filter { !hidden.contains($0.id) })
    case .disabled:
        return .disabled
    }
}

/// The account's own matches (its chats and contacts) only.
func excludingChatsHiddenFromLists(myResults: [FoundPeer], _ hidden: Set<PeerId>) -> [FoundPeer] {
    return myResults.filter { !hidden.contains($0.peer.id) }
}

/// Dual PIN: gives the restricted mode its own copy of every activity list
/// (`Namespaces.OrderedItemList.restrictedModeSeparateLists`) for as long as the result is held.
public func addRestrictedModeListRedirections(postbox: Postbox) -> Disposable {
    let disposables = DisposableSet()
    for collectionId in Namespaces.OrderedItemList.restrictedModeSeparateLists {
        disposables.add(postbox.addOrderedItemListRedirection(from: collectionId, to: Namespaces.OrderedItemList.restrictedModeList(for: collectionId)))
    }
    return disposables
}
