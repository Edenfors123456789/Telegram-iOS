import Foundation

/// Unread counters as views report them while chats are hidden (`Postbox.addHiddenChatIds`):
/// the stored totals less the hidden chats' share, the way the chat lists leave the chats
/// themselves out. Storage keeps the real totals, so nothing has to be undone when the set
/// is released. A hidden chat contributes what `ChatListIndexTable` files for it: per counter
/// tag `max(count, markedUnread ? 1 : 0)` messages and one chat if unread, to the filtered
/// counters only when it is not removed from the total; per namespace its count and one chat.
extension PostboxImpl {
    /// The read state a chat is counted with: a forum's topic summary, otherwise its own.
    private func counterReadState(of peer: Peer) -> CombinedPeerReadState? {
        var displayAsRegularChat = false
        if let cachedData = self.cachedPeerDataTable.get(peer.id), self.seedConfiguration.decodeDisplayPeerAsRegularChat(cachedData) {
            displayAsRegularChat = true
        }
        if self.seedConfiguration.peerSummaryIsThreadBased(peer, peer.associatedPeerId.flatMap(self.peerTable.get)).value && !displayAsRegularChat {
            let count = self.peerThreadsSummaryTable.get(peerId: peer.id)?.effectiveUnreadCount ?? 0
            return CombinedPeerReadState(states: [(0, .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 1, maxKnownId: 0, count: count, markedUnread: false))])
        }
        return self.readStateTable.getCombinedState(peer.id)
    }

    /// Hidden chats filed into `groupId`'s counters, with the read state they are counted with.
    private func hiddenChatsCounted(in groupId: PeerGroupId) -> [(Peer, CombinedPeerReadState)] {
        var result: [(Peer, CombinedPeerReadState)] = []
        for peerId in self.hiddenChatIds {
            guard self.chatListIndexTable.get(peerId: peerId).includedIndex(peerId: peerId)?.0 == groupId,
                  let peer = self.peerTable.get(peerId), let readState = self.counterReadState(of: peer) else {
                continue
            }
            result.append((peer, readState))
        }
        return result
    }

    func visibleTotalUnreadState(groupId: PeerGroupId) -> ChatListTotalUnreadState {
        var state = self.messageHistoryMetadataTable.getTotalUnreadState(groupId: groupId)
        guard self.hasHiddenChatIds else {
            return state
        }
        let hidden = self.hiddenChatsCounted(in: groupId)
        if hidden.isEmpty {
            return state
        }
        let globalSettings = self.globalNotificationSettingsOutsideTransaction()
        func subtract(_ counters: ChatListTotalUnreadCounters?, messages: Int32, chats: Int32) -> ChatListTotalUnreadCounters? {
            return counters.flatMap { ChatListTotalUnreadCounters(messageCount: max(0, $0.messageCount - messages), chatCount: max(0, $0.chatCount - chats)) }
        }
        for (peer, readState) in hidden {
            let notificationPeerId: PeerId
            if let associatedPeerId = peer.associatedPeerId, peer.associatedPeerOverridesIdentity {
                notificationPeerId = associatedPeerId
            } else {
                notificationPeerId = peer.id
            }
            let isContact = self.contactsTable.isContact(peerId: notificationPeerId)
            let messages = max(readState.count, readState.markedUnread ? 1 : 0)
            let chats: Int32 = readState.isUnread ? 1 : 0
            let isFiltered = !resolvedIsRemovedFromTotalUnreadCount(globalSettings: globalSettings, peer: peer, peerSettings: self.peerNotificationSettingsTable.getEffective(notificationPeerId))
            for tag in self.seedConfiguration.peerSummaryCounterTags(peer, isContact) {
                state.absoluteCounters[tag] = subtract(state.absoluteCounters[tag], messages: messages, chats: chats)
                if isFiltered {
                    state.filteredCounters[tag] = subtract(state.filteredCounters[tag], messages: messages, chats: chats)
                }
            }
        }
        return state
    }

    func visibleGroupUnreadSummary(groupId: PeerGroupId) -> PeerGroupUnreadCountersCombinedSummary {
        var summary = self.groupMessageStatsTable.get(groupId: groupId)
        guard self.hasHiddenChatIds else {
            return summary
        }
        for (_, readState) in self.hiddenChatsCounted(in: groupId) {
            for (namespace, namespaceState) in readState.states where namespaceState.count > 0 {
                if var counters = summary.namespaces[namespace] {
                    counters.all.chatCount = max(0, counters.all.chatCount - 1)
                    counters.all.messageCount = max(0, counters.all.messageCount - namespaceState.count)
                    summary.namespaces[namespace] = counters
                }
            }
        }
        return summary
    }

    /// Nil for a hidden chat: it counts as read.
    func visibleCombinedReadState(peerId: PeerId, _ readState: () -> CombinedPeerReadState?) -> CombinedPeerReadState? {
        if self.isChatHidden(peerId: peerId) {
            return nil
        }
        return readState()
    }
}
