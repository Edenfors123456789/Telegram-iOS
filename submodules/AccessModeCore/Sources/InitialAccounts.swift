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

extension AccessConfiguration {
    public static func initial(installation: UUID, accounts: [InitialSetupAccount],
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
