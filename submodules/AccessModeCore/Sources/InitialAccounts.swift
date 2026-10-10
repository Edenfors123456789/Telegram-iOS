import Foundation

/// Values must come from each actual authorized record's self peer. A display
/// name, phone number, selected array index or unconfirmed login is insufficient.
public struct InitialSetupAccount: Equatable, Sendable {
    public let observed: ObservedAccount
    public let isPremium: Bool
    public init(observed: ObservedAccount, isPremium: Bool) {
        self.observed = observed; self.isPremium = isPremium
    }
}

/// Non-logged-out AccountManager metadata, independent of loaded peer results.
/// The native caller must also report any current authorization record.
public struct InitialAccountRecord: Hashable, Sendable {
    public let recordID: Int64
    public let environment: AccountEnvironment
    public init(recordID: Int64, environment: AccountEnvironment) {
        self.recordID = recordID; self.environment = environment
    }
}

extension AccessConfiguration {
    public static func initial(installation: UUID, records: [InitialAccountRecord], hasPendingAuthorization: Bool,
                               accounts: [InitialSetupAccount], sharedAccount: ObservedAccount) throws -> AccessConfiguration {
        let loaded = accounts.map { InitialAccountRecord(recordID: $0.observed.recordID, environment: $0.observed.environment) }
        guard !hasPendingAuthorization, !records.isEmpty, records.count == accounts.count,
              Set(records.map(\.recordID)).count == records.count,
              Set(loaded.map(\.recordID)).count == loaded.count,
              Set(records) == Set(loaded) else { throw AccessError.invalidConfiguration }
        return try buildInitial(installation: installation, accounts: accounts, sharedAccount: sharedAccount)
    }

    private static func buildInitial(installation: UUID, accounts: [InitialSetupAccount],
                                     sharedAccount: ObservedAccount) throws -> AccessConfiguration {
        guard !accounts.isEmpty, accounts.contains(where: { $0.observed == sharedAccount }),
              accounts.allSatisfy({ $0.observed.userNamespace == 0 && $0.observed.userID > 0 }) else {
            throw AccessError.invalidConfiguration
        }
        func identity(_ observed: ObservedAccount) -> AccountIdentity {
            AccountIdentity(installation: installation, environment: observed.environment,
                recordID: observed.recordID, userID: observed.userID)
        }
        let selected = identity(sharedAccount)
        return try AccessConfiguration(installation: installation, accounts: accounts.map {
            AccountMembership(identity: identity($0.observed), ownership: $0.observed == sharedAccount ? .shared : .a,
                isPremium: $0.isPremium)
        }, selectedA: selected, selectedB: selected)
    }
}
