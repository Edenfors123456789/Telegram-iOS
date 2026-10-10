import Foundation

/// Not Codable: a saved owner or copied flow ID cannot authorize completion.
public struct AccountEnrollmentPermit {
    let issuer: UUID
    let flowID: UUID
}

struct PendingAccountEnrollment: Codable {
    let flowID: UUID
    let mode: AccessMode
    let configurationRevision: UInt64
    let revocation: UInt64
    var provisionalRecordID: Int64? = nil
}

extension AccessCredentialStore {
    func selectAccount(_ account: AccountIdentity, grant: AuthenticatedModeGrant) throws -> AuthenticatedModeGrant {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: issuer)
            let config = state.configuration
            guard config.revision < UInt64.max,
                  AccessModePolicy(mode: grant.mode, configuration: config).allowsAccount(account) else { throw AccessError.invalidConfiguration }
            state.configuration = try AccessConfiguration(installation: config.installation, revision: config.revision + 1,
                accounts: config.accounts, hiddenChats: config.hiddenChats, hiddenChatGenerations: config.hiddenChatGenerations,
                selectedA: grant.mode == .a ? account : config.selectedA,
                selectedB: grant.mode == .b ? account : config.selectedB)
            state.pendingEnrollment = nil
            stored = state
            return self.grant(mode: grant.mode, state: state)
        }
    }

    func beginEnrollment(grant: AuthenticatedModeGrant) throws -> AccountEnrollmentPermit {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: issuer)
            guard state.pendingEnrollment == nil, state.pendingEnrollmentCleanup == nil else { throw AccessError.invalidTransition }
            let flowID = UUID()
            state.pendingEnrollment = PendingAccountEnrollment(flowID: flowID, mode: grant.mode,
                configurationRevision: state.configuration.revision, revocation: state.revocation)
            stored = state
            return AccountEnrollmentPermit(issuer: issuer, flowID: flowID)
        }
    }

    func cancelEnrollment(_ permit: AccountEnrollmentPermit, grant: AuthenticatedModeGrant) throws {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: issuer)
            try requireEnrollment(permit, grant: grant, state: state)
            state.pendingEnrollment = nil
            stored = state
        }
    }

    /// Bind the freshly created raw auth record before exposing its authorization UI.
    /// A callback for another record cannot adopt it or clean up an existing account.
    func bindEnrollment(_ permit: AccountEnrollmentPermit, provisionalRecordID: Int64, environment: AccountEnvironment = .production, grant: AuthenticatedModeGrant) throws {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: issuer)
            try requireEnrollment(permit, grant: grant, state: state)
            guard !state.configuration.accounts.contains(where: { $0.identity.recordID == provisionalRecordID }),
                  state.pendingEnrollment!.provisionalRecordID == nil || state.pendingEnrollment!.provisionalRecordID == provisionalRecordID else {
                throw AccessError.invalidConfiguration
            }
            if let cleanup = state.pendingEnrollmentCleanup {
                guard cleanup.flowID == permit.flowID, cleanup.provisionalRecordID == provisionalRecordID,
                      cleanup.environment == environment, cleanup.claimID == nil else { throw AccessError.staleAuthorization }
            } else {
                state.pendingEnrollmentCleanup = PendingEnrollmentCleanup(flowID: permit.flowID, installation: state.configuration.installation,
                    mode: grant.mode, provisionalRecordID: provisionalRecordID, environment: environment, claimID: nil)
            }
            // Earlier readers must not ignore durable cleanup ownership.
            state.version = max(state.version, 3)
            state.pendingEnrollment!.provisionalRecordID = provisionalRecordID
            stored = state
        }
    }

    func bindEnrollmentSessionKey(_ permit: AccountEnrollmentPermit, sessionKey: AccountEnrollmentSessionKey, grant: AuthenticatedModeGrant) throws {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: issuer)
            try requireEnrollment(permit, grant: grant, state: state)
            guard sessionKey.isValid, let record = state.pendingEnrollment?.provisionalRecordID,
                  var cleanup = state.pendingEnrollmentCleanup, cleanup.flowID == permit.flowID,
                  cleanup.provisionalRecordID == record, cleanup.claimID == nil else { throw AccessError.staleAuthorization }
            var keys = cleanup.sessionKeys ?? []
            if let existing = keys.first(where: { $0.datacenterID == sessionKey.datacenterID }) {
                guard existing == sessionKey else { throw AccessError.invalidConfiguration }
            } else {
                guard keys.count < 32 else { throw AccessError.invalidConfiguration }
                keys.append(sessionKey)
            }
            // Track attempts only from the first key on: a ledger that already
            // held untracked keys keeps requiring every one of them.
            if cleanup.sessionKeys == nil { cleanup.authorizationAttempts = cleanup.authorizationAttempts ?? [] }
            cleanup.sessionKeys = keys
            state.pendingEnrollmentCleanup = cleanup
            state.version = max(state.version, cleanup.authorizationAttempts == nil ? 4 : 6)
            stored = state
        }
    }

    /// Write-ahead: durable before the authorizing request is sent. A mark that
    /// adds nothing (repeat, or an untracked ledger) is validated without a write.
    func markEnrollmentAuthorizationAttempt(_ permit: AccountEnrollmentPermit, sessionKey: AccountEnrollmentSessionKey, grant: AuthenticatedModeGrant) throws {
        func attempts(_ state: AccessVaultState) throws -> [AccountEnrollmentSessionKey]? {
            try state.require(grant, issuer: issuer)
            try requireEnrollment(permit, grant: grant, state: state)
            guard sessionKey.isValid, let record = state.pendingEnrollment?.provisionalRecordID,
                  let cleanup = state.pendingEnrollmentCleanup, cleanup.flowID == permit.flowID,
                  cleanup.provisionalRecordID == record, cleanup.claimID == nil,
                  cleanup.sessionKeys?.contains(sessionKey) == true else { throw AccessError.staleAuthorization }
            // Untracked: every bound key is already required.
            guard let attempts = cleanup.authorizationAttempts, !attempts.contains(sessionKey) else { return nil }
            return attempts
        }
        guard try file.withReadState({ try attempts($0) }) != nil else { return }
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            guard let current = try attempts(state) else { return }
            state.pendingEnrollmentCleanup!.authorizationAttempts = current + [sessionKey]
            stored = state
        }
    }

    /// The Telegram adapter supplies confirmed self identity, never a phone/name.
    /// Unavailable means it must revoke/remove ONLY its provisional session.
    func completeEnrollment(_ permit: AccountEnrollmentPermit, confirmedAccount: AccountIdentity,
                            isPremium: Bool, grant: AuthenticatedModeGrant) throws -> (AccountEnrollmentDecision, AuthenticatedModeGrant) {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: issuer)
            try requireEnrollment(permit, grant: grant, state: state)
            let config = state.configuration
            guard confirmedAccount.installation == config.installation, confirmedAccount.userID > 0,
                  state.pendingEnrollment?.provisionalRecordID == confirmedAccount.recordID,
                  let cleanup = state.pendingEnrollmentCleanup, cleanup.flowID == permit.flowID, cleanup.claimID == nil,
                  cleanup.provisionalRecordID == confirmedAccount.recordID, cleanup.environment == confirmedAccount.environment else { throw AccessError.invalidConfiguration }
            var decision = AccessModePolicy(mode: grant.mode, configuration: config).enrollment(
                environment: confirmedAccount.environment, userID: confirmedAccount.userID, isPremium: isPremium)
            if case let .new(ownership) = decision {
                if config.accounts.contains(where: { $0.identity.recordID == confirmedAccount.recordID }) {
                    decision = .unavailable
                } else {
                    guard config.revision < UInt64.max else { throw AccessError.corrupt }
                    state.configuration = try AccessConfiguration(installation: config.installation, revision: config.revision + 1,
                        accounts: config.accounts + [AccountMembership(identity: confirmedAccount, ownership: ownership, isPremium: isPremium)],
                        hiddenChats: config.hiddenChats, hiddenChatGenerations: config.hiddenChatGenerations,
                        selectedA: grant.mode == .a ? confirmedAccount : config.selectedA,
                        selectedB: grant.mode == .b ? confirmedAccount : config.selectedB)
                    state.pendingEnrollmentCleanup = nil
                }
            }
            state.pendingEnrollment = nil
            stored = state
            return (decision, self.grant(mode: grant.mode, state: state))
        }
    }

    private func requireEnrollment(_ permit: AccountEnrollmentPermit, grant: AuthenticatedModeGrant, state: AccessVaultState) throws {
        guard permit.issuer == issuer, let pending = state.pendingEnrollment,
              permit.flowID == pending.flowID, pending.mode == grant.mode,
              pending.configurationRevision == grant.configurationRevision,
              pending.revocation == grant.revocation else { throw AccessError.staleAuthorization }
    }
}
