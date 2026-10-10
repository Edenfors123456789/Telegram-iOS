import UIKit

public struct PINManagementFeedbackTicket { let owner: UUID; let operation: UUID }
public struct PINManagementFeedbackRevision { let owner: UUID; let revision: UUID }

/// Main-thread presentation bookkeeping only: no PIN, role or access authority.
/// A cancelled worker still owns its pending cover until its exact completion.
public final class PINManagementFeedback {
    public enum Failure: Error { case busy }
    private let owner = UUID()
    private var pending: UUID?
    private var cancelled = false
    private var revision = UUID()
    public private(set) var hasFailure = false
    public init() {}
    public var isPending: Bool { pending != nil }
    public func begin() throws -> PINManagementFeedbackTicket {
        precondition(Thread.isMainThread)
        guard pending == nil else { throw Failure.busy }
        let operation = UUID()
        pending = operation; cancelled = false; hasFailure = false; revision = UUID()
        return PINManagementFeedbackTicket(owner: owner, operation: operation)
    }
    @discardableResult public func finish(_ ticket: PINManagementFeedbackTicket, failed: Bool) -> Bool {
        precondition(Thread.isMainThread)
        guard ticket.owner == owner, pending == ticket.operation else { return false }
        pending = nil; hasFailure = failed && !cancelled; cancelled = false; revision = UUID()
        return true
    }
    public func invalidate() {
        precondition(Thread.isMainThread)
        if pending != nil { cancelled = true }
        hasFailure = false; revision = UUID()
    }
    public func captureRevision() -> PINManagementFeedbackRevision {
        precondition(Thread.isMainThread)
        return PINManagementFeedbackRevision(owner: owner, revision: revision)
    }
    @discardableResult public func clearRecoveredFailure(_ snapshot: PINManagementFeedbackRevision) -> Bool {
        precondition(Thread.isMainThread)
        guard snapshot.owner == owner, snapshot.revision == revision, pending == nil else { return false }
        hasFailure = false; revision = UUID()
        return true
    }
}
