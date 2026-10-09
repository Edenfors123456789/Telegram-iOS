import Foundation

/// An identity observed from a loaded Telegram record, never an ownership claim.
/// Telegram cloud-user peers use namespace zero; other namespaces are quarantined.
public struct ObservedAccount: Hashable, Sendable {
    public let environment: AccountEnvironment
    public let recordID: Int64
    public let userNamespace: Int32
    public let userID: Int64

    public init(environment: AccountEnvironment, recordID: Int64, userNamespace: Int32, userID: Int64) {
        self.environment = environment
        self.recordID = recordID
        self.userNamespace = userNamespace
        self.userID = userID
    }
}

public struct AccountProjection: Equatable, Sendable {
    public let primary: AccountIdentity?
    public let accounts: [AccountIdentity]
}

extension AccessModePolicy {
    /// Match all observed identity fields against verified ownership. Preserve raw
    /// display order, but never copy the raw primary/fallback or adopt unknown rows.
    public func projectAccounts(_ observed: [ObservedAccount]) throws -> AccountProjection {
        try configuration.validate()
        guard Set(observed.map(\.recordID)).count == observed.count else { throw AccessError.invalidConfiguration }
        struct ServerIdentity: Hashable { let environment: AccountEnvironment; let userID: Int64 }
        let users = observed.filter { $0.userNamespace == 0 && $0.userID > 0 }
        guard Set(users.map { ServerIdentity(environment: $0.environment, userID: $0.userID) }).count == users.count else {
            throw AccessError.invalidConfiguration
        }
        let members = visibleAccounts
        let result = users.compactMap { raw in
            members.first { $0.recordID == raw.recordID && $0.environment == raw.environment && $0.userID == raw.userID }
        }
        return AccountProjection(primary: result.contains(selectedAccount) ? selectedAccount : nil, accounts: result)
    }
}
