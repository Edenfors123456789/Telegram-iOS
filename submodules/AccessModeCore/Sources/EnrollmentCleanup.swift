import Foundation

/// Cleanup-only authority, never an account/data or enrollment-completion grant.
public struct AccountEnrollmentCleanupTicket {
    let issuer: UUID
    let claimID: UUID
    let flowID: UUID
    public let provisionalRecordID: Int64
    public let environment: AccountEnvironment
}

struct PendingEnrollmentCleanup: Codable {
    let flowID: UUID
    let installation: UUID
    let mode: AccessMode
    let provisionalRecordID: Int64
    let environment: AccountEnvironment
    var claimID: UUID?
    var sessionKeys: [AccountEnrollmentSessionKey]? = nil
    var revokedSessions: [EnrollmentSessionRevocationRecord]? = nil
    /// Keys an authorizing request may have used; nil means untracked (all bound keys).
    var authorizationAttempts: [AccountEnrollmentSessionKey]? = nil

    /// An untracked ledger cannot tell which keys signed in, so all stay required.
    var keysRequiringRevocation: [AccountEnrollmentSessionKey] {
        authorizationAttempts ?? sessionKeys ?? []
    }

    func validate(configuration: AccessConfiguration) throws {
        guard installation == configuration.installation,
              !configuration.accounts.contains(where: { $0.identity.recordID == provisionalRecordID }) else { throw AccessError.corrupt }
        if let sessionKeys {
            guard !sessionKeys.isEmpty, sessionKeys.count <= 32,
                  sessionKeys.allSatisfy({ $0.isValid }),
                  Set(sessionKeys.map(\.datacenterID)).count == sessionKeys.count else { throw AccessError.corrupt }
        }
        if let authorizationAttempts {
            guard let sessionKeys, authorizationAttempts.count <= sessionKeys.count,
                  Set(authorizationAttempts.map(\.datacenterID)).count == authorizationAttempts.count,
                  authorizationAttempts.allSatisfy({ $0.isValid && sessionKeys.contains($0) }) else { throw AccessError.corrupt }
        }
        if let revokedSessions {
            guard let claimID, let sessionKeys, !revokedSessions.isEmpty,
                  revokedSessions.count <= sessionKeys.count,
                  Set(revokedSessions.map { $0.sessionKey.datacenterID }).count == revokedSessions.count,
                  revokedSessions.allSatisfy({ $0.claimID == claimID && $0.sessionKey.isValid && sessionKeys.contains($0.sessionKey) }) else {
                throw AccessError.corrupt
            }
        }
    }
}

extension AccessCredentialStore {
    func withUnownedAccountDirectory<T>(recordID: Int64, _ body: () throws -> T) throws -> T? {
        try file.withReadState { state in
            try state.validate()
            guard !state.configuration.accounts.contains(where: { $0.identity.recordID == recordID }),
                  state.pendingEnrollmentCleanup?.provisionalRecordID != recordID else { return nil }
            // Keep ownership publication excluded until the filesystem action
            // returns. No snapshot or later queued callback can grant deletion.
            return try body()
        }
    }

    private func requireEnrollmentCleanup(_ ticket: AccountEnrollmentCleanupTicket, state: AccessVaultState) throws {
        try state.validate()
        guard ticket.issuer == issuer, let cleanup = state.pendingEnrollmentCleanup,
              cleanup.claimID == ticket.claimID, cleanup.flowID == ticket.flowID,
              cleanup.provisionalRecordID == ticket.provisionalRecordID, cleanup.environment == ticket.environment,
              state.pendingEnrollment == nil else { throw AccessError.staleAuthorization }
    }

    /// Hold the durable read lock through the small synchronous metadata action.
    /// The callback must not reenter the vault or enqueue network/async work.
    func withEnrollmentCleanup<T>(_ ticket: AccountEnrollmentCleanupTicket, _ body: () throws -> T) throws -> T {
        try file.withReadState { state in
            try requireEnrollmentCleanup(ticket, state: state)
            return try body()
        }
    }

    func boundEnrollmentSessionKeys(_ ticket: AccountEnrollmentCleanupTicket) throws -> [AccountEnrollmentSessionKey] {
        try file.withReadState { state in
            try requireEnrollmentCleanup(ticket, state: state)
            return state.pendingEnrollmentCleanup!.sessionKeys ?? []
        }
    }

    func recordEnrollmentSessionRevocation(_ ticket: AccountEnrollmentCleanupTicket, sessionKey: AccountEnrollmentSessionKey) throws {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try requireEnrollmentCleanup(ticket, state: state)
            guard sessionKey.isValid, var cleanup = state.pendingEnrollmentCleanup,
                  cleanup.sessionKeys?.contains(sessionKey) == true else { throw AccessError.staleAuthorization }
            var receipts = cleanup.revokedSessions ?? []
            if let existing = receipts.first(where: { $0.sessionKey.datacenterID == sessionKey.datacenterID }) {
                guard existing.claimID == ticket.claimID, existing.sessionKey == sessionKey else { throw AccessError.staleAuthorization }
            } else {
                receipts.append(EnrollmentSessionRevocationRecord(claimID: ticket.claimID, sessionKey: sessionKey))
            }
            cleanup.revokedSessions = receipts
            state.pendingEnrollmentCleanup = cleanup
            state.version = max(state.version, 5)
            try state.validate()
            stored = state
        }
    }

    func enrollmentSessionKeysRequiringRevocation(_ ticket: AccountEnrollmentCleanupTicket) throws -> [AccountEnrollmentSessionKey] {
        try file.withReadState { state in
            try requireEnrollmentCleanup(ticket, state: state)
            return state.pendingEnrollmentCleanup!.keysRequiringRevocation
        }
    }

    func confirmedEnrollmentSessionKeys(_ ticket: AccountEnrollmentCleanupTicket) throws -> [AccountEnrollmentSessionKey] {
        try file.withReadState { state in
            try requireEnrollmentCleanup(ticket, state: state)
            return state.pendingEnrollmentCleanup!.revokedSessions?.map(\.sessionKey) ?? []
        }
    }

    /// Claim before touching AccountManager. Claiming cancels completion authority
    /// durably, so the same provisional record cannot become a member mid-cleanup.
    func claimEnrollmentCleanup() throws -> AccountEnrollmentCleanupTicket? {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.validate()
            guard var cleanup = state.pendingEnrollmentCleanup else { return nil }
            if let pending = state.pendingEnrollment {
                guard pending.flowID == cleanup.flowID else { throw AccessError.corrupt }
                state.pendingEnrollment = nil
            }
            if cleanup.claimID == nil { cleanup.claimID = UUID() }
            state.pendingEnrollmentCleanup = cleanup
            stored = state
            return AccountEnrollmentCleanupTicket(issuer: issuer, claimID: cleanup.claimID!, flowID: cleanup.flowID,
                provisionalRecordID: cleanup.provisionalRecordID, environment: cleanup.environment)
        }
    }

    /// Native adapter acknowledges only after exact record/session cleanup and
    /// an authoritative absence check. This ticket grants no display authority.
    /// Every key an authorizing request may have used needs its own receipt
    /// first. A key never marked as attempted, or an owner that never bound a
    /// key, needs none: authorization may use only an already-marked bound key.
    func acknowledgeEnrollmentCleanup(_ ticket: AccountEnrollmentCleanupTicket) throws {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try requireEnrollmentCleanup(ticket, state: state)
            let cleanup = state.pendingEnrollmentCleanup!
            let revoked = (cleanup.revokedSessions ?? []).map(\.sessionKey)
            guard cleanup.keysRequiringRevocation.allSatisfy(revoked.contains) else { throw AccessError.invalidTransition }
            state.pendingEnrollmentCleanup = nil
            stored = state
        }
    }
}
