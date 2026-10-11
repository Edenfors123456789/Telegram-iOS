import Foundation

/// What every history view of one chat may show while the restriction is held
/// (`Postbox.addHistoryRestriction`); Dual PIN's restricted transcript. Decided from the stored
/// message header only. Storage, network processing and `Transaction` reads are unaffected.
public struct MessageHistoryRestriction: Equatable {
    public struct Boundary: Equatable {
        /// Per namespace, the newest message that existed when the transcript began.
        public var maximumMessageIds: [MessageId.Namespace: MessageId.Id]
        /// Server time at the boundary.
        public var serverTimestamp: Int32

        public init(maximumMessageIds: [MessageId.Namespace: MessageId.Id], serverTimestamp: Int32) {
            self.maximumMessageIds = maximumMessageIds
            self.serverTimestamp = serverTimestamp
        }
    }

    /// Nil until an authoritative boundary is known: no incoming message is admitted.
    public var boundary: Boundary?
    /// Messages at or before this time are never shown.
    public var windowStart: Int32
    /// Random ids of the sends made from the restricted mode.
    public var outgoingGloballyUniqueIds: Set<Int64>
    /// Sends from the restricted mode that are known by id: confirmed messages stored without
    /// their random id (an album's confirmation does that), adopted when they replace one.
    public var outgoingMessageIds: Set<MessageId>
    public var deletedMessageIds: Set<MessageId>
    /// Messages carrying any of these global tags are never shown (Dual PIN: calls).
    public var excludedGlobalTags: GlobalMessageTags

    public init(boundary: Boundary?, windowStart: Int32, outgoingGloballyUniqueIds: Set<Int64>, outgoingMessageIds: Set<MessageId> = [], deletedMessageIds: Set<MessageId>, excludedGlobalTags: GlobalMessageTags = []) {
        self.boundary = boundary
        self.windowStart = windowStart
        self.outgoingGloballyUniqueIds = outgoingGloballyUniqueIds
        self.outgoingMessageIds = outgoingMessageIds
        self.deletedMessageIds = deletedMessageIds
        self.excludedGlobalTags = excludedGlobalTags
    }

    public func includes(id: MessageId, timestamp: Int32, flags: MessageFlags, globallyUniqueId: Int64?, globalTags: GlobalMessageTags = []) -> Bool {
        if timestamp <= self.windowStart || self.deletedMessageIds.contains(id) || !globalTags.intersection(self.excludedGlobalTags).isEmpty {
            return false
        }
        if flags.contains(.Incoming) {
            guard let boundary = self.boundary, let maximumId = boundary.maximumMessageIds[id.namespace] else {
                return false
            }
            return id.id > maximumId && timestamp >= boundary.serverTimestamp
        } else {
            if self.outgoingMessageIds.contains(id) {
                return true
            }
            guard let globallyUniqueId else {
                return false
            }
            return self.outgoingGloballyUniqueIds.contains(globallyUniqueId)
        }
    }

    func includes(_ message: IntermediateMessage) -> Bool {
        return self.includes(id: message.id, timestamp: message.timestamp, flags: message.flags, globallyUniqueId: message.globallyUniqueId, globalTags: message.globalTags)
    }

    func includes(_ message: Message) -> Bool {
        return self.includes(id: message.id, timestamp: message.timestamp, flags: message.flags, globallyUniqueId: message.globallyUniqueId, globalTags: message.globalTags)
    }

    /// Holes at or below this id are never loaded for `namespace`: everything there is excluded.
    func holeFloor(namespace: MessageId.Namespace) -> MessageId.Id {
        return self.boundary?.maximumMessageIds[namespace] ?? Int32.max
    }
}

extension PostboxImpl {
    /// `message` as a view may show it: nil if its chat's restriction excludes it, and without
    /// associated messages (reply and quote sources) that their chats' restrictions exclude.
    func visibleUnderHistoryRestrictions(_ message: Message?) -> Message? {
        guard let message, self.hasHistoryRestrictions else {
            return message
        }
        if let restriction = self.historyRestriction(peerId: message.id.peerId), !restriction.includes(message) {
            return nil
        }
        return self.strippingRestrictedAssociatedMessages(message)
    }

    /// A send the restriction admits stays admitted when it is replaced, even if the replacement
    /// (a confirmed album message) no longer carries the random id it was admitted by.
    func adoptRestrictedSendReplacement(previous: IntermediateMessage, updated: StoreMessage) {
        guard self.hasHistoryRestrictions, !previous.flags.contains(.Incoming),
              case let .Id(updatedId) = updated.id, updatedId.peerId == previous.id.peerId,
              let restriction = self.historyRestriction(peerId: previous.id.peerId), restriction.includes(previous) else {
            return
        }
        if let globallyUniqueId = updated.globallyUniqueId, restriction.outgoingGloballyUniqueIds.contains(globallyUniqueId) {
            return
        }
        self.updateHistoryRestriction(peerId: previous.id.peerId) { restriction in
            var restriction = restriction
            restriction.outgoingMessageIds.insert(updatedId)
            return restriction
        }
    }

    /// A message group (album) without the members the restriction excludes.
    func visibleUnderHistoryRestrictions(group: [Message]) -> [Message] {
        guard self.hasHistoryRestrictions else {
            return group
        }
        return group.compactMap { self.visibleUnderHistoryRestrictions($0) }
    }

    func strippingRestrictedAssociatedMessages(_ message: Message) -> Message {
        guard self.hasHistoryRestrictions, !message.associatedMessages.isEmpty else {
            return message
        }
        var excluded = Set<MessageId>()
        for (id, associatedMessage) in message.associatedMessages {
            if let restriction = self.historyRestriction(peerId: id.peerId), !restriction.includes(associatedMessage) {
                excluded.insert(id)
            }
        }
        if let kept = message.associatedMessages.filteredOut(keysIn: excluded) {
            return message.withUpdatedAssociatedMessages(kept)
        }
        return message
    }

    /// The restrictions held for `peerIds`, as a snapshot for one view state (a change resets
    /// the views of its chat, which take a new snapshot).
    func historyRestrictions(peerIds: [PeerId]) -> [PeerId: MessageHistoryRestriction] {
        var result: [PeerId: MessageHistoryRestriction] = [:]
        if self.hasHistoryRestrictions {
            for peerId in peerIds {
                if let restriction = self.historyRestriction(peerId: peerId) {
                    result[peerId] = restriction
                }
            }
        }
        return result
    }
}

extension MessageHistoryViewInput {
    /// The chats whose restrictions this view applies.
    var restrictablePeerIds: [PeerId] {
        switch self {
        case let .single(peerId, _):
            return [peerId]
        case let .associated(peerId, associatedId):
            return [peerId] + (associatedId.map { [$0.peerId] } ?? [])
        case let .external(input):
            switch input.content {
            case let .thread(peerId, _, _):
                return [peerId]
            case .messages:
                return []
            }
        }
    }
}
