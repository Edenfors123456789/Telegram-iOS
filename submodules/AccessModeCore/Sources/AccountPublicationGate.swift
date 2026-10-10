import Foundation

public struct InitialAccountPublicationTicket {
    let owner: UUID
    let generation: UUID
}

/// Quarantines raw account streams during initial setup. This does not authenticate
/// accounts or replace the mode policy. Required mode access can never be cleared.
public final class AccessAccountPublicationGate {
    private enum State { case ordinary, initial(UUID), required }
    private let owner = UUID()
    private let mutex = NSLock()
    private var state: State
    public init(modeRequired: Bool = false) { state = modeRequired ? .required : .ordinary }
    public var requiresModePolicy: Bool {
        mutex.lock(); defer { mutex.unlock() }
        if case .ordinary = state { return false }
        return true
    }
    public func beginInitialPreparation() throws -> InitialAccountPublicationTicket {
        mutex.lock(); defer { mutex.unlock() }
        guard case .ordinary = state else { throw AccessError.invalidTransition }
        let generation = UUID()
        state = .initial(generation)
        return InitialAccountPublicationTicket(owner: owner, generation: generation)
    }
    public func requireModePolicy() {
        mutex.lock(); defer { mutex.unlock() }
        state = .required
    }
    /// Native adapter may call this only after a successful durable absent-state
    /// inspection, while its fresh legacy PIN cover is retained.
    public func restoreConfirmedUnconfigured(_ ticket: InitialAccountPublicationTicket) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard ticket.owner == owner, case let .initial(generation) = state,
              ticket.generation == generation else { throw AccessError.staleAuthorization }
        state = .ordinary
    }
}
