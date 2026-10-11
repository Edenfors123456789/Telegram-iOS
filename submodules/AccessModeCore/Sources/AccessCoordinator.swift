import Foundation

public enum AccessPresentationState: Equatable { case locked, preparing(AccessMode), active(AccessMode) }
public enum AccessProcess { case mainApplication, shareExtension }

public struct AccessTicket {
    let coordinator: UUID
    let generation: UUID
}

/// Capture synchronously at PIN submission, before dispatching expensive work.
public struct AccessPINRequest {
    let coordinator: UUID
    let generation: UUID
}

public struct AccessPINChangeRequest {
    let coordinator: UUID
    let generation: UUID
    let grant: AuthenticatedModeGrant
}

public struct AccessJournalRecoveryRequest {
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

    var permitsPINManagement: Bool { process == .mainApplication }
    var permitsChatManagement: Bool { process == .mainApplication }

    public func lock() throws {
        mutex.lock(); defer { mutex.unlock() }
        invalidate()
        // Local invalidation precedes I/O and survives protected-data/storage failure.
        if process == .mainApplication { try store.revokeAll() }
    }

    public func beginUnlock(pin: String) throws -> AccessTicket {
        try beginUnlock(pin: pin, request: preparePINRequest())
    }

    public func preparePINRequest() throws -> AccessPINRequest {
        mutex.lock(); defer { mutex.unlock() }
        try lock()
        return AccessPINRequest(coordinator: id, generation: generation)
    }

    public func beginUnlock(pin: String, request: AccessPINRequest) throws -> AccessTicket {
        mutex.lock(); defer { mutex.unlock() }
        guard request.coordinator == id, request.generation == generation, presentation == .locked else { throw AccessError.staleAuthorization }
        // Consume once even when PIN verification fails.
        generation = UUID()
        let verified = try store.authenticate(pin: pin)
        grant = verified
        presentation = .preparing(verified.mode)
        return AccessTicket(coordinator: id, generation: generation)
    }

    public func cooldownRemaining() throws -> Int {
        mutex.lock(); defer { mutex.unlock() }
        return try store.cooldownRemaining()
    }

    public func preparePINChange(ticket: AccessTicket) throws -> AccessPINChangeRequest {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: true)
        guard permitsPINManagement else { throw AccessError.authenticationRequired }
        // Local invalidation precedes persistent work and survives its failure.
        invalidate()
        let temporary = try store.revokeAndReissueForPINChange(verified)
        presentation = .preparing(temporary.mode)
        return AccessPINChangeRequest(coordinator: id, generation: generation, grant: temporary)
    }

    /// Dispatch only after main-thread preparation covered/detached the root.
    /// The trusted adapter must verify the own current PIN and use the A journal
    /// or the B-only replacement API. It must not retain the temporary grant.
    /// No completion can authenticate a root, including after a committed change.
    public func executePINChange(_ request: AccessPINChangeRequest, operation: (AuthenticatedModeGrant) throws -> Void) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard permitsPINManagement, request.coordinator == id, request.generation == generation,
              presentation == .preparing(request.grant.mode), grant == nil else { throw AccessError.staleAuthorization }
        generation = UUID()
        let execution = generation
        let result = Result {
            try store.validatePINChangeGrant(request.grant)
            try operation(request.grant)
        }
        // Reentrant newer authentication/locking must survive an old completion.
        guard generation == execution else { throw AccessError.staleAuthorization }
        invalidate()
        do { try store.revokeAll() }
        catch { if case .success = result { throw error } }
        try result.get()
    }

    public func prepareJournalRecovery() throws -> AccessJournalRecoveryRequest? {
        mutex.lock(); defer { mutex.unlock() }
        guard permitsPINManagement else { throw AccessError.authenticationRequired }
        guard presentation == .locked, grant == nil else { throw AccessError.invalidTransition }
        invalidate()
        guard try store.hasPendingOwnerPINChange() else { return nil }
        // Presentation preparation only: no user credential has been verified,
        // and there is no grant for account/data/settings access.
        presentation = .preparing(.a)
        return AccessJournalRecoveryRequest(coordinator: id, generation: generation)
    }

    /// Trusted main-process recovery on the worker queue. The operation must
    /// complete the pending journal, including durable resource/ref publication.
    /// Failure/duplicate/stale completion cannot open a root or unlock with an
    /// old code. Background lock revokes queued requests like normal PIN work.
    public func executeJournalRecovery(_ request: AccessJournalRecoveryRequest, operation: () throws -> Void) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard permitsPINManagement, request.coordinator == id, request.generation == generation,
              presentation == .preparing(.a), grant == nil else { throw AccessError.staleAuthorization }
        generation = UUID()
        let execution = generation
        let result = Result {
            guard try store.hasPendingOwnerPINChange() else { throw AccessError.invalidTransition }
            try operation()
            guard try !store.hasPendingOwnerPINChange() else { throw AccessError.unavailable }
        }
        guard generation == execution else { throw AccessError.staleAuthorization }
        invalidate()
        do { try store.revokeAll() }
        catch { if case .success = result { throw error } }
        try result.get()
    }

    public func cancelPreparation(_ ticket: AccessTicket) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard ticket.coordinator == id, ticket.generation == generation else { return }
        let verified = try requireLocal(ticket, requireReady: false)
        guard presentation == .preparing(verified.mode) else { throw AccessError.invalidTransition }
        invalidate()
        if process == .mainApplication { try store.revoke(verified) }
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

    /// Restricted-transcript work of the ready B root, main application only. The grant must
    /// not outlive `body`; the transcript store revalidates it on every call anyway.
    func withRestrictedTranscriptGrant<T>(_ ticket: AccessTicket, _ body: (AuthenticatedModeGrant) throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: true)
        guard process == .mainApplication, verified.mode == .b else { throw AccessError.authenticationRequired }
        return try body(verified)
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

    public func bindEnrollment(_ permit: AccountEnrollmentPermit, provisionalRecordID: Int64, environment: AccountEnvironment = .production, ticket: AccessTicket) throws {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: true)
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        do { try store.bindEnrollment(permit, provisionalRecordID: provisionalRecordID, environment: environment, grant: verified) }
        catch { invalidate(); throw error }
    }

    /// Persist before authorization can use this original persistent key.
    public func bindEnrollmentSessionKey(_ permit: AccountEnrollmentPermit, sessionKey: AccountEnrollmentSessionKey, ticket: AccessTicket) throws {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: true)
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        do { try store.bindEnrollmentSessionKey(permit, sessionKey: sessionKey, grant: verified) }
        catch { invalidate(); throw error }
    }

    /// Call and succeed before sending any request that may authorize this key,
    /// QR login-token export included. A failure means the request is not sent.
    public func markEnrollmentAuthorizationAttempt(_ permit: AccountEnrollmentPermit, sessionKey: AccountEnrollmentSessionKey, ticket: AccessTicket) throws {
        mutex.lock(); defer { mutex.unlock() }
        let verified = try requireLocal(ticket, requireReady: true)
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        do { try store.markEnrollmentAuthorizationAttempt(permit, sessionKey: sessionKey, grant: verified) }
        catch { invalidate(); throw error }
    }

    /// The keys whose server logout must be confirmed before acknowledgment.
    public func enrollmentSessionKeysRequiringRevocation(_ cleanup: AccountEnrollmentCleanupTicket) throws -> [AccountEnrollmentSessionKey] {
        mutex.lock(); defer { mutex.unlock() }
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        return try store.enrollmentSessionKeysRequiringRevocation(cleanup)
    }

    public func boundEnrollmentSessionKeys(_ cleanup: AccountEnrollmentCleanupTicket) throws -> [AccountEnrollmentSessionKey] {
        mutex.lock(); defer { mutex.unlock() }
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        return try store.boundEnrollmentSessionKeys(cleanup)
    }

    /// Native adapter calls only after consuming its verified opaque RPC result.
    public func recordEnrollmentSessionRevocation(_ cleanup: AccountEnrollmentCleanupTicket, sessionKey: AccountEnrollmentSessionKey) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        try store.recordEnrollmentSessionRevocation(cleanup, sessionKey: sessionKey)
    }

    /// Exact recorded keys only; an empty result never proves server cleanup.
    public func confirmedEnrollmentSessionKeys(_ cleanup: AccountEnrollmentCleanupTicket) throws -> [AccountEnrollmentSessionKey] {
        mutex.lock(); defer { mutex.unlock() }
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        return try store.confirmedEnrollmentSessionKeys(cleanup)
    }

    public func claimEnrollmentCleanup() throws -> AccountEnrollmentCleanupTicket? {
        mutex.lock(); defer { mutex.unlock() }
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        return try store.claimEnrollmentCleanup()
    }

    public func acknowledgeEnrollmentCleanup(_ ticket: AccountEnrollmentCleanupTicket) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        try store.acknowledgeEnrollmentCleanup(ticket)
    }

    /// Synchronous metadata boundary; never enqueue network work in this body.
    public func withEnrollmentCleanup<T>(_ ticket: AccountEnrollmentCleanupTicket, _ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        return try store.withEnrollmentCleanup(ticket, body)
    }

    /// Background deletion permission only, never an unlock or cleanup proof.
    /// Caller must separately validate fresh native metadata and the exact path.
    /// Body must be synchronous, without vault reentry or queued network work.
    public func withUnownedAccountDirectory<T>(recordID: Int64, _ body: () throws -> T) throws -> T? {
        mutex.lock(); defer { mutex.unlock() }
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        return try store.withUnownedAccountDirectory(recordID: recordID, body)
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
