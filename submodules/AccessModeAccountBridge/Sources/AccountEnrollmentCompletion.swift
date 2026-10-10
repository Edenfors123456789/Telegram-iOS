import Foundation
import AccessModeCore
import TelegramCore
import SwiftSignalKit

public enum AccountEnrollmentCleanupCompletion: Equatable {
    /// The owned raw record is absent and the ledger is acknowledged. The local
    /// directory is released to the gated background cleanup, not deleted here.
    case completed
    /// A key that an authorizing request may have used has no receipt yet;
    /// nothing was changed.
    case awaitingRevocation
    case unavailable
}

extension AccountEnrollmentBridge {
    /// Runs after the scoped logouts. The record is removed the way upstream
    /// logout removes it, and only a later transaction, which sees that removal
    /// committed, may acknowledge. A crash in between leaves an owned ledger
    /// with an absent record, which a retry completes; the reverse order could
    /// drop the ledger while the record survives.
    public static func completeProvisionalCleanup(accountManager: AccountManager<TelegramAccountManagerTypes>,
        coordinator: AccessModeCoordinator, cleanup: AccountEnrollmentCleanupTicket) -> Signal<AccountEnrollmentCleanupCompletion, NoError> {
        let removal = accountManager.transaction { transaction -> AccountEnrollmentCleanupCompletion in
            do {
                // Each read validates the owner. They stay outside the read gate
                // below, which must not reenter the vault.
                let confirmed = try coordinator.confirmedEnrollmentSessionKeys(cleanup)
                guard try coordinator.enrollmentSessionKeysRequiringRevocation(cleanup).allSatisfy(confirmed.contains) else { return .awaitingRevocation }
                return try coordinator.withEnrollmentCleanup(cleanup) {
                    let id = AccountRecordId(rawValue: cleanup.provisionalRecordID)
                    guard cleanupMetadataIsDetached(transaction: transaction, recordID: id.int64,
                        environment: cleanup.environment, cleanup: cleanup) else { return .unavailable }
                    if transaction.getRecords().contains(where: { $0.id == id }) {
                        transaction.updateRecord(id, { _ in nil })
                    }
                    return .completed
                }
            } catch { return .unavailable }
        }
        return removal |> mapToSignal { result -> Signal<AccountEnrollmentCleanupCompletion, NoError> in
            guard result == .completed else { return .single(result) }
            return accountManager.transaction { transaction -> AccountEnrollmentCleanupCompletion in
                do {
                    let id = AccountRecordId(rawValue: cleanup.provisionalRecordID)
                    guard try coordinator.withEnrollmentCleanup(cleanup, {
                        cleanupMetadataIsDetached(transaction: transaction, recordID: id.int64,
                            environment: cleanup.environment, cleanup: cleanup)
                            && !transaction.getRecords().contains(where: { $0.id == id })
                    }) else { return .unavailable }
                    // Core rechecks every receipt under its write lock.
                    try coordinator.acknowledgeEnrollmentCleanup(cleanup)
                    return .completed
                } catch { return .unavailable }
            }
        }
    }
}
