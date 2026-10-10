import Foundation
import AccessModeCore
import TelegramCore
import SwiftSignalKit

public enum AccountEnrollmentCleanupJobResult: Equatable {
    /// The owned record is absent and the ledger acknowledged.
    case completed
    /// A required server logout is not confirmed yet; everything is retained.
    case retryLater
    case unavailable
}

extension AccountEnrollmentBridge {
    /// Detach, then revoke one at a time each key an authorizing request may
    /// have used and that has no receipt yet, then complete locally. `revoke`
    /// is trusted for nothing: a key counts as revoked only once Core holds its
    /// receipt, so an empty or lying signal leaves the owner for a retry. The
    /// caller claims first and owns when to retry; nothing here polls.
    public static func runProvisionalCleanup(accountManager: AccountManager<TelegramAccountManagerTypes>,
        coordinator: AccessModeCoordinator, cleanup: AccountEnrollmentCleanupTicket,
        revoke: @escaping (AccountEnrollmentSessionKey) -> Signal<Void, NoError>) -> Signal<AccountEnrollmentCleanupJobResult, NoError> {
        func nextUnconfirmed() throws -> AccountEnrollmentSessionKey? {
            let confirmed = try coordinator.confirmedEnrollmentSessionKeys(cleanup)
            return try coordinator.enrollmentSessionKeysRequiringRevocation(cleanup).first(where: { !confirmed.contains($0) })
        }
        func complete() -> Signal<AccountEnrollmentCleanupJobResult, NoError> {
            return completeProvisionalCleanup(accountManager: accountManager, coordinator: coordinator, cleanup: cleanup)
            |> map { result -> AccountEnrollmentCleanupJobResult in
                switch result {
                case .completed: return .completed
                case .awaitingRevocation: return .retryLater
                case .unavailable: return .unavailable
                }
            }
        }
        func revokeRemaining() -> Signal<AccountEnrollmentCleanupJobResult, NoError> {
            // Read Core when subscribed, not when the signal is built.
            return deferred { () -> Signal<AccountEnrollmentCleanupJobResult, NoError> in
                let key: AccountEnrollmentSessionKey?
                do { key = try nextUnconfirmed() } catch { return .single(.unavailable) }
                guard let key else { return complete() }
                // Wait for the attempt to finish, whatever it emits, then ask Core.
                return (revoke(key) |> take(1) |> filter { _ in false } |> then(Signal<Void, NoError>.single(())))
                |> mapToSignal { _ -> Signal<AccountEnrollmentCleanupJobResult, NoError> in
                    let confirmed: Bool
                    do { confirmed = try coordinator.confirmedEnrollmentSessionKeys(cleanup).contains(key) }
                    catch { return .single(.unavailable) }
                    // Each pass confirms one more key, so this ends.
                    return confirmed ? revokeRemaining() : .single(.retryLater)
                }
            }
        }
        return detachAuthForCleanup(accountManager: accountManager, coordinator: coordinator, cleanup: cleanup)
        |> mapToSignal { detached -> Signal<AccountEnrollmentCleanupJobResult, NoError> in
            guard detached == .detached else { return .single(.unavailable) }
            return revokeRemaining()
        }
    }
}
