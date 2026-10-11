import Foundation
import AccessModeCore
import Postbox

public enum RestrictedTranscriptRestriction {
    /// The Postbox history restriction that shows exactly `snapshot`'s transcript of `chat`.
    /// Nil when a value cannot be represented in Postbox's 32-bit fields: the caller must then
    /// not open the chat at all rather than show it unrestricted. Messages with any of
    /// `excludedGlobalTags` never show (the app passes the call tags: a hidden chat's calls stay
    /// out of B even inside its transcript, user decision 2026-10-12).
    public static func historyRestriction(chat: ChatIdentity, snapshot: RestrictedTranscriptSnapshot, excludedGlobalTags: GlobalMessageTags) -> MessageHistoryRestriction? {
        guard let peerId = peerId(chat), let windowStart = Int32(exactly: max(0, snapshot.windowStart)) else {
            return nil
        }
        var boundary: MessageHistoryRestriction.Boundary?
        if let value = snapshot.boundary {
            guard let serverTimestamp = Int32(exactly: value.serverTimestamp) else {
                return nil
            }
            boundary = MessageHistoryRestriction.Boundary(maximumMessageIds: value.maximumMessageIDs, serverTimestamp: serverTimestamp)
        }
        var outgoingMessageIds = Set<MessageId>()
        for id in snapshot.sendServerIDs {
            guard id.chat == chat else {
                return nil
            }
            outgoingMessageIds.insert(MessageId(peerId: peerId, namespace: id.namespace, id: id.id))
        }
        var deletedMessageIds = Set<MessageId>()
        for id in snapshot.deleted {
            guard id.chat == chat else {
                return nil
            }
            deletedMessageIds.insert(MessageId(peerId: peerId, namespace: id.namespace, id: id.id))
        }
        return MessageHistoryRestriction(boundary: boundary, windowStart: windowStart, outgoingGloballyUniqueIds: snapshot.sendRandomIDs,
            outgoingMessageIds: outgoingMessageIds, deletedMessageIds: deletedMessageIds, excludedGlobalTags: excludedGlobalTags)
    }

    static func peerId(_ chat: ChatIdentity) -> PeerId? {
        guard chat.peerID > 0, chat.peerID <= 0x00ff_ffff_ffff_ffff else {
            return nil
        }
        return PeerId(namespace: PeerId.Namespace._internalFromInt32Value(chat.peerNamespace), id: PeerId.Id._internalFromInt64Value(chat.peerID))
    }
}
