import Foundation

/// Push is disabled in both modes (plan §7). Earlier builds registered every signed-in account
/// for APNs and VoIP pushes; this ledger names the server registrations still to be cancelled
/// with `account.unregisterDevice`. An entry leaves only on the server's answer: an unconfirmed
/// cancellation does not count as done.
///
/// The ledger is written once, at the first launch of a build that never registers, from the
/// accounts signed in at that moment. Accounts signed in later never registered and never
/// enter it. Accounts are the account manager's record ids.
public struct PushRegistrationCleanupLedger: Codable, Equatable {
    public enum TokenType: String, Codable, CaseIterable {
        case aps
        case voip
    }

    private struct Entry: Codable, Hashable {
        let account: Int64
        let type: TokenType
    }

    private let version: Int
    private var pending: Set<Entry>

    private init(pending: Set<Entry>) {
        self.version = 1
        self.pending = pending
    }

    /// The stored ledger, without accounts no longer signed in (their logout ended their
    /// registrations). Nothing stored means the first launch. Storage that cannot be read
    /// starts over from the accounts signed in now: cancelling a registration that no longer
    /// exists is harmless, missing one is not.
    public static func load(_ data: Data?, signedInAccounts: Set<Int64>) -> PushRegistrationCleanupLedger {
        var ledger: PushRegistrationCleanupLedger
        if let data, let stored = try? JSONDecoder().decode(PushRegistrationCleanupLedger.self, from: data), stored.version == 1 {
            ledger = stored
        } else {
            ledger = PushRegistrationCleanupLedger(pending: Set(signedInAccounts.flatMap { account in
                TokenType.allCases.map { Entry(account: account, type: $0) }
            }))
        }
        ledger.pending = ledger.pending.filter { signedInAccounts.contains($0.account) }
        return ledger
    }

    public var isEmpty: Bool {
        return self.pending.isEmpty
    }

    public func pendingTypes(account: Int64) -> Set<TokenType> {
        return Set(self.pending.filter { $0.account == account }.map(\.type))
    }

    /// The server answered the cancellation of this registration.
    public mutating func acknowledge(account: Int64, type: TokenType) {
        self.pending.remove(Entry(account: account, type: type))
    }

    public func encoded() throws -> Data {
        return try JSONEncoder().encode(self)
    }
}
