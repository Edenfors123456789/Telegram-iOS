import Foundation
import AccessModeCore
import TelegramCore
import SwiftSignalKit

public enum AccountEnrollmentCreation {
    case created(recordID: AccountRecordId, permit: AccountEnrollmentPermit)
    case unavailable
}

public enum AccountEnrollmentAuthCancellation: Equatable {
    /// Only the owned auth entry is absent; session/record cleanup is still pending.
    case detached
    case unavailable
}

/// Metadata only. Native caller must cover and validate its originating UI/root.
public enum AccountEnrollmentBridge {
    public static func detachAuthForCleanup(accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        cleanup: AccountEnrollmentCleanupTicket) -> Signal<AccountEnrollmentAuthCancellation, NoError> {
        // Idempotent submitted cleanup is allowed to drain even when its
        // observer is disposed. The durable claim already canceled enrollment.
        return accountManager.transaction { transaction -> AccountEnrollmentAuthCancellation in
            do {
                return try coordinator.withEnrollmentCleanup(cleanup) {
                    guard let auth = transaction.getCurrentAuth(), auth.id.int64 == cleanup.provisionalRecordID else {
                        // An unrelated current auth is never ours to remove.
                        return .detached
                    }
                    let environments = auth.attributes.compactMap { attribute -> Bool? in
                        guard case let .environment(value) = attribute else { return nil }
                        switch value.environment {
                        case .production: return false
                        case .test: return true
                        }
                    }
                    guard environments.count <= 1, (environments.first ?? false) == (cleanup.environment == .test) else {
                        return .unavailable
                    }
                    transaction.removeAuth()
                    // No record deletion, session proof or ledger acknowledgment.
                    return .detached
                }
            } catch { return .unavailable }
        }
    }

    public static func createProvisionalAccount(accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        ticket: AccessTicket, environment: AccessModeCore.AccountEnvironment) -> Signal<AccountEnrollmentCreation, NoError> {
        createProvisionalAccount(accountManager: accountManager, coordinator: coordinator, ticket: ticket,
            environment: environment, beforeDirectoryReservation: { _ in })
    }

    /// The hook lets tests place an entry at the randomly allocated path.
    static func createProvisionalAccount(accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        ticket: AccessTicket, environment: AccessModeCore.AccountEnvironment,
        beforeDirectoryReservation: @escaping (AccountRecordId) -> Void) -> Signal<AccountEnrollmentCreation, NoError> {
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
                beforeDirectoryReservation(record.id)
                // Nor may a raw ID without a record adopt an orphaned directory's
                // existing Postbox and keys as the new provisional session.
                guard let reserved = reserveAccountDirectory(accountManager: accountManager, recordID: record.id) else {
                    if transaction.getCurrentAuth()?.id == record.id { transaction.removeAuth() }
                    try? coordinator.cancelEnrollment(permit, ticket: ticket)
                    return .unavailable
                }
                do {
                    try coordinator.bindEnrollment(permit, provisionalRecordID: record.id.int64, environment: environment, ticket: ticket)
                    guard !cancelled.with({ $0 }) else {
                        if transaction.getCurrentAuth()?.id == record.id { transaction.removeAuth() }
                        rmdir(reserved)
                        try? coordinator.cancelEnrollment(permit, ticket: ticket)
                        // Keep durable cleanup: binding may already have committed.
                        return .unavailable
                    }
                    return .created(recordID: record.id, permit: permit)
                } catch {
                    // This callback has not published/synced yet. Leave other flows
                    // and records intact; a partially durable ledger survives retry.
                    if transaction.getCurrentAuth()?.id == record.id { transaction.removeAuth() }
                    rmdir(reserved)
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

    /// Exclusively creates the canonical directory of a freshly allocated ID.
    /// mkdir fails for any existing entry, a symlink or dangling one included.
    /// Rollback uses rmdir, which removes only a still-empty directory.
    static func reserveAccountDirectory(accountManager: AccountManager<TelegramAccountManagerTypes>, recordID: AccountRecordId) -> String? {
        let metadata = URL(fileURLWithPath: accountManager.basePath).standardizedFileURL
        guard metadata.lastPathComponent == "accounts-metadata" else { return nil }
        let path = metadata.deletingLastPathComponent().appendingPathComponent(accountRecordIdPathName(recordID)).path
        return mkdir(path, 0o700) == 0 ? path : nil
    }
}
