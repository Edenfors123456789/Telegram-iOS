import Foundation

public enum AccessPresentationState: Equatable { case locked, preparing(AccessMode), active(AccessMode) }
public enum AccessProcess { case mainApplication, shareExtension }

public struct AccessTicket {
    let coordinator: UUID
    let generation: UUID
}

/// The UI attaches its opaque cover before calling lock/beginUnlock and removes it
/// only after completePreparation. Tickets must be rechecked at async delivery/side effects.
public final class AccessModeCoordinator {
    private let id = UUID()
    private let mutex = NSRecursiveLock()
    private let store: AccessCredentialStore
    private let process: AccessProcess
    private var generation = UUID()
    private var grant: AuthenticatedModeGrant?
    private var presentation: AccessPresentationState = .locked

    public init(store: AccessCredentialStore, process: AccessProcess = .mainApplication) {
        self.store = store
        self.process = process
    }

    public var state: AccessPresentationState {
        mutex.lock(); defer { mutex.unlock() }
        return presentation
    }

    public func lock() throws {
        mutex.lock(); defer { mutex.unlock() }
        invalidate()
        // Local invalidation precedes I/O and survives protected-data/storage failure.
        if process == .mainApplication { try store.revokeAll() }
    }

    public func beginUnlock(pin: String) throws -> AccessTicket {
        mutex.lock(); defer { mutex.unlock() }
        try lock()
        let verified = try store.authenticate(pin: pin)
        grant = verified
        presentation = .preparing(verified.mode)
        return AccessTicket(coordinator: id, generation: generation)
    }

    public func completePreparation(_ ticket: AccessTicket) throws {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: false)
        guard presentation == .preparing(verified.mode) else { throw AccessError.invalidTransition }
        do {
            _ = try store.configuration(grant: verified)
            presentation = .active(verified.mode)
        } catch { invalidate(); throw error }
    }

    public func withPolicy<T>(_ ticket: AccessTicket, requireReady: Bool = true, _ body: (AccessModePolicy) throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: requireReady)
        let config: AccessConfiguration
        do {
            config = try store.configuration(grant: verified)
        } catch {
            invalidate()
            throw error
        }
        return try body(AccessModePolicy(mode: verified.mode, configuration: config))
    }

    /// Attach the cover before calling; replacement authority remains preparing until
    /// the UI has discarded old results and prepared the new revision/root.
    public func setHidden(_ chat: ChatIdentity, hidden: Bool, ticket: AccessTicket) throws -> AccessTicket {
        try mutate(ticket) {
            try store.setHidden(chat, hidden: hidden, grant: $0, expectedRevision: $0.configurationRevision)
        }
    }

    public func selectAccount(_ account: AccountIdentity, ticket: AccessTicket) throws -> AccessTicket {
        try mutate(ticket) { try store.selectAccount(account, grant: $0) }
    }

    public func beginEnrollment(ticket: AccessTicket) throws -> AccountEnrollmentPermit {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: true)
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        do { return try store.beginEnrollment(grant: verified) }
        catch { invalidate(); throw error }
    }

    public func cancelEnrollment(_ permit: AccountEnrollmentPermit, ticket: AccessTicket) throws {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: true)
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        do { try store.cancelEnrollment(permit, grant: verified) }
        catch { invalidate(); throw error }
    }

    public func bindEnrollment(_ permit: AccountEnrollmentPermit, provisionalRecordID: Int64, ticket: AccessTicket) throws {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: true)
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        do { try store.bindEnrollment(permit, provisionalRecordID: provisionalRecordID, grant: verified) }
        catch { invalidate(); throw error }
    }

    public func completeEnrollment(_ permit: AccountEnrollmentPermit, confirmedAccount: AccountIdentity,
                                   isPremium: Bool, ticket: AccessTicket) throws -> (decision: AccountEnrollmentDecision, ticket: AccessTicket) {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: true)
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        do {
            let (decision, updated) = try store.completeEnrollment(permit, confirmedAccount: confirmedAccount, isPremium: isPremium, grant: verified)
            return (decision, replaceAfterMutation(updated))
        } catch { invalidate(); throw error }
    }

    private func mutate(_ ticket: AccessTicket, _ operation: (AuthenticatedModeGrant) throws -> AuthenticatedModeGrant) throws -> AccessTicket {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: true)
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        do { return replaceAfterMutation(try operation(verified)) }
        catch { invalidate(); throw error }
    }

    private func replaceAfterMutation(_ updated: AuthenticatedModeGrant) -> AccessTicket {
        generation = UUID()
        grant = updated
        presentation = .preparing(updated.mode)
        return AccessTicket(coordinator: id, generation: generation)
    }

    private func requireLocal(_ ticket: AccessTicket, requireReady: Bool) throws -> AuthenticatedModeGrant {
        guard ticket.coordinator == id, ticket.generation == generation, let grant,
              !requireReady || presentation == .active(grant.mode) else { throw AccessError.staleAuthorization }
        return grant
    }

    private func invalidate() {
        generation = UUID()
        grant = nil
        presentation = .locked
    }
}
