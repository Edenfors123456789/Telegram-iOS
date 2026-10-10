import Foundation
import AccessModeCore
import TelegramCore
import SwiftSignalKit

public enum AccountEnrollmentCreation {
    case created(recordID: AccountRecordId, permit: AccountEnrollmentPermit)
    case unavailable
}

/// Metadata only. Native caller must cover and validate its originating UI/root.
public enum AccountEnrollmentBridge {
    public static func createProvisionalAccount(accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        ticket: AccessTicket, environment: AccessModeCore.AccountEnvironment) -> Signal<AccountEnrollmentCreation, NoError> {
        // A retained signal cannot allocate a second flow after its first owner
        // has been resolved. Each deliberate attempt needs a new invocation.
        let consumed = Atomic<Bool>(value: false)
        return Signal { subscriber in
            guard !consumed.swap(true) else {
                subscriber.putNext(.unavailable)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let cancelled = Atomic<Bool>(value: false)
            let disposable = accountManager.transaction { transaction -> AccountEnrollmentCreation in
                // Upstream's queued transaction ignores subscription disposal.
                guard !cancelled.with({ $0 }), transaction.getCurrentAuth() == nil else { return .unavailable }
                let permit: AccountEnrollmentPermit
                do { permit = try coordinator.beginEnrollment(ticket: ticket) }
                catch { return .unavailable }
                guard !cancelled.with({ $0 }) else {
                    try? coordinator.cancelEnrollment(permit, ticket: ticket)
                    return .unavailable
                }
                guard let record = transaction.createAuth([
                    .environment(AccountEnvironmentAttribute(environment: environment == .test ? .test : .production))
                ]) else {
                    try? coordinator.cancelEnrollment(permit, ticket: ticket)
                    return .unavailable
                }
                // The allocator must not turn a collision with any existing raw
                // record (even unregistered) into authority to remove that record.
                guard !transaction.getRecords().contains(where: { $0.id == record.id }) else {
                    if transaction.getCurrentAuth()?.id == record.id { transaction.removeAuth() }
                    try? coordinator.cancelEnrollment(permit, ticket: ticket)
                    return .unavailable
                }
                do {
                    try coordinator.bindEnrollment(permit, provisionalRecordID: record.id.int64, environment: environment, ticket: ticket)
                    guard !cancelled.with({ $0 }) else {
                        if transaction.getCurrentAuth()?.id == record.id { transaction.removeAuth() }
                        try? coordinator.cancelEnrollment(permit, ticket: ticket)
                        // Keep durable cleanup: binding may already have committed.
                        return .unavailable
                    }
                    return .created(recordID: record.id, permit: permit)
                } catch {
                    // This callback has not published/synced yet. Leave other flows
                    // and records intact; a partially durable ledger survives retry.
                    if transaction.getCurrentAuth()?.id == record.id { transaction.removeAuth() }
                    try? coordinator.cancelEnrollment(permit, ticket: ticket)
                    return .unavailable
                }
            }.start(next: { subscriber.putNext($0) }, completed: { subscriber.putCompletion() })
            return ActionDisposable {
                _ = cancelled.swap(true)
                disposable.dispose()
            }
        }
    }
}
