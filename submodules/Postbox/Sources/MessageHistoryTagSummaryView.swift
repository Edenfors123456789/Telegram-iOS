import Foundation

final class MutableMessageHistoryTagSummaryView: MutablePostboxView {
    private let tag: MessageTags
    private let peerId: PeerId
    private let threadId: Int64?
    private let namespace: MessageId.Namespace
    private let customTag: MemoryBuffer?
    
    fileprivate var count: Int32?
    
    init(postbox: PostboxImpl, tag: MessageTags, peerId: PeerId, threadId: Int64?, namespace: MessageId.Namespace, customTag: MemoryBuffer?) {
        self.tag = tag
        self.peerId = peerId
        self.threadId = threadId
        self.namespace = namespace
        self.customTag = customTag
        
        self.count = postbox.messageHistoryTagsSummaryTable.get(MessageHistoryTagsSummaryKey(tag: tag, peerId: peerId, threadId: threadId, namespace: namespace, customTag: customTag))?.count
        if postbox.historyRestriction(peerId: peerId) != nil {
            self.count = self.restrictedCount(postbox: postbox)
        }
    }
    
    /// A restricted chat counts only what its views may show (a custom-tag summary: nothing).
    private func restrictedCount(postbox: PostboxImpl) -> Int32 {
        if self.customTag != nil {
            return 0
        }
        return postbox.restrictedTaggedMessageCount(peerId: self.peerId, threadId: self.threadId, namespace: self.namespace, tag: self.tag)
    }
    
    func replay(postbox: PostboxImpl, transaction: PostboxTransaction) -> Bool {
        var hasChanges = false
        
        if postbox.historyRestriction(peerId: self.peerId) != nil {
            if transaction.updatedHistoryRestrictionPeerIds.contains(self.peerId) || transaction.currentOperationsByPeerId[self.peerId] != nil {
                let count = self.restrictedCount(postbox: postbox)
                if count != self.count {
                    self.count = count
                    hasChanges = true
                }
            }
            return hasChanges
        }
        if transaction.updatedHistoryRestrictionPeerIds.contains(self.peerId) {
            self.count = postbox.messageHistoryTagsSummaryTable.get(MessageHistoryTagsSummaryKey(tag: self.tag, peerId: self.peerId, threadId: self.threadId, namespace: self.namespace, customTag: self.customTag))?.count
            hasChanges = true
        }
        if let summary = transaction.currentUpdatedMessageTagSummaries[MessageHistoryTagsSummaryKey(tag: self.tag, peerId: self.peerId, threadId: self.threadId, namespace: self.namespace, customTag: self.customTag)] {
            self.count = summary.count
            hasChanges = true
        }
        
        return hasChanges
    }

    func refreshDueToExternalTransaction(postbox: PostboxImpl) -> Bool {
        return false
    }
    
    func immutableView() -> PostboxView {
        return MessageHistoryTagSummaryView(self)
    }
}

public final class MessageHistoryTagSummaryView: PostboxView {
    public let count: Int32?
    
    init(_ view: MutableMessageHistoryTagSummaryView) {
        self.count = view.count
    }
}
