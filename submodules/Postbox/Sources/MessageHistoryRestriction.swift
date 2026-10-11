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
    public var deletedMessageIds: Set<MessageId>

    public init(boundary: Boundary?, windowStart: Int32, outgoingGloballyUniqueIds: Set<Int64>, deletedMessageIds: Set<MessageId>) {
        self.boundary = boundary
        self.windowStart = windowStart
        self.outgoingGloballyUniqueIds = outgoingGloballyUniqueIds
        self.deletedMessageIds = deletedMessageIds
    }

    public func includes(id: MessageId, timestamp: Int32, flags: MessageFlags, globallyUniqueId: Int64?) -> Bool {
        if timestamp <= self.windowStart || self.deletedMessageIds.contains(id) {
            return false
        }
        if flags.contains(.Incoming) {
            guard let boundary = self.boundary, let maximumId = boundary.maximumMessageIds[id.namespace] else {
                return false
            }
            return id.id > maximumId && timestamp >= boundary.serverTimestamp
        } else {
            guard let globallyUniqueId else {
                return false
            }
            return self.outgoingGloballyUniqueIds.contains(globallyUniqueId)
        }
    }

    func includes(_ message: IntermediateMessage) -> Bool {
        return self.includes(id: message.id, timestamp: message.timestamp, flags: message.flags, globallyUniqueId: message.globallyUniqueId)
    }

    func includes(_ message: Message) -> Bool {
        return self.includes(id: message.id, timestamp: message.timestamp, flags: message.flags, globallyUniqueId: message.globallyUniqueId)
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
