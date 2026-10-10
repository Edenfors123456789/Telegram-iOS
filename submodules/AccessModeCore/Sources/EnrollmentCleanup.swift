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

    func validate(configuration: AccessConfiguration) throws {
        guard installation == configuration.installation,
              !configuration.accounts.contains(where: { $0.identity.recordID == provisionalRecordID }) else { throw AccessError.corrupt }
    }
}

extension AccessCredentialStore {
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
    func acknowledgeEnrollmentCleanup(_ ticket: AccountEnrollmentCleanupTicket) throws {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try requireEnrollmentCleanup(ticket, state: state)
            state.pendingEnrollmentCleanup = nil
            stored = state
        }
    }
}
