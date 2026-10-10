import Foundation
import AccessModeCore
import TelegramCore
import TelegramApi
import SwiftSignalKit

enum AccountEnrollmentLogoutReply {
    case loggedOut
    case rpcError(code: Int32, type: String)
    case unavailable
}

protocol AccountEnrollmentLogoutTransport: AnyObject {
    var recordID: Int64 { get }
    var environment: AccessModeCore.AccountEnvironment { get }
    var hasOriginalAuthorizationBinding: Bool { get }
    var isOriginalSessionCurrent: Bool { get }
    /// The exact original key a confirmed reply revokes; nil never confirms.
    var revokedSessionKey: AccountEnrollmentSessionKey? { get }
    func logout() -> Signal<AccountEnrollmentLogoutReply, NoError>
}

extension AccountEnrollmentLogoutTransport {
    var hasOriginalAuthorizationBinding: Bool { false }
    var isOriginalSessionCurrent: Bool { false }
}

/// Ephemeral server-result authority, never an unlock or account-display grant.
public struct AccountEnrollmentSessionRevocation {
    fileprivate let accountManager: AccountManager<TelegramAccountManagerTypes>
    fileprivate let coordinator: AccessModeCoordinator
    fileprivate let cleanup: AccountEnrollmentCleanupTicket
}

public enum AccountEnrollmentLogoutResult {
    case confirmed(AccountEnrollmentSessionRevocation)
    case unavailable
}

extension AccountEnrollmentBridge {
    public static func revokeProvisionalSession(account: AccountResult, accountManager: AccountManager<TelegramAccountManagerTypes>,
        coordinator: AccessModeCoordinator, cleanup: AccountEnrollmentCleanupTicket) -> Signal<AccountEnrollmentLogoutResult, NoError> {
        guard let source = NativeEnrollmentSessionKeySource(account: account),
              source.recordID == cleanup.provisionalRecordID, source.environment == cleanup.environment,
              matchesNativeRoot(basePath: source.basePath, recordID: source.recordID, accountManager: accountManager) else {
            return .single(.unavailable)
        }
        let stopServiceTasks: () -> Void
        switch account {
        case .upgrading: return .single(.unavailable)
        case let .authorized(value): stopServiceTasks = { value.shouldBeServiceTaskMaster.set(.single(.never)) }
        case let .unauthorized(value): stopServiceTasks = { value.shouldBeServiceTaskMaster.set(.single(.never)) }
        }
        let transport = ScopedEnrollmentLogoutTransport(source: source, accountManager: accountManager,
            coordinator: coordinator, cleanup: cleanup, engineKind: { source.network.engineKind }, stopServiceTasks: stopServiceTasks,
            request: { scope in
                source.network.request(Api.functions.auth.logOut(), automaticFloodWait: false, authKeyScope: scope)
                |> map { _ in () }
            })
        return revokeSession(transport: transport, accountManager: accountManager, coordinator: coordinator, cleanup: cleanup)
    }

    static func isConfirmedSessionLogout(_ reply: AccountEnrollmentLogoutReply) -> Bool {
        switch reply {
        case .loggedOut: return true
        case let .rpcError(code, type):
            if code == 401 {
                return ["AUTH_KEY_UNREGISTERED", "AUTH_KEY_INVALID", "SESSION_REVOKED", "SESSION_EXPIRED"].contains(type)
            }
            return code == 406 && type == "AUTH_KEY_DUPLICATED"
        case .unavailable: return false
        }
    }

    static func revokeSession(transport: AccountEnrollmentLogoutTransport, accountManager: AccountManager<TelegramAccountManagerTypes>,
        coordinator: AccessModeCoordinator, cleanup: AccountEnrollmentCleanupTicket,
        timeoutSeconds: Double = 15) -> Signal<AccountEnrollmentLogoutResult, NoError> {
        let consumed = Atomic<Bool>(value: false)
        return Signal { subscriber in
            guard !consumed.swap(true), timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 60 else {
                subscriber.putNext(.unavailable); subscriber.putCompletion()
                return EmptyDisposable
            }
            let cancelled = Atomic<Bool>(value: false), emitted = Atomic<Bool>(value: false)
            let ready = accountManager.transaction { transaction -> Bool in
                guard !cancelled.with({ $0 }), transport.isOriginalSessionCurrent else { return false }
                do {
                    return try coordinator.withEnrollmentCleanup(cleanup) {
                        cleanupMetadataIsDetached(transaction: transaction, recordID: transport.recordID,
                            environment: transport.environment, cleanup: cleanup)
                    }
                } catch { return false }
            }
            let request = ready |> mapToSignal { allowed -> Signal<AccountEnrollmentLogoutResult, NoError> in
                guard allowed, !cancelled.with({ $0 }), transport.isOriginalSessionCurrent,
                      let sessionKey = transport.revokedSessionKey else { return .single(.unavailable) }
                return transport.logout()
                |> timeout(timeoutSeconds, queue: Queue.concurrentDefaultQueue(), alternate: .single(.unavailable))
                |> take(1)
                |> mapToSignal { reply -> Signal<AccountEnrollmentLogoutResult, NoError> in
                    guard !cancelled.with({ $0 }), transport.isOriginalSessionCurrent,
                          isConfirmedSessionLogout(reply) else { return .single(.unavailable) }
                    if case .rpcError = reply, !transport.hasOriginalAuthorizationBinding { return .single(.unavailable) }
                    return accountManager.transaction { transaction -> AccountEnrollmentLogoutResult in
                        guard !cancelled.with({ $0 }), transport.isOriginalSessionCurrent else { return .unavailable }
                        do {
                            guard try coordinator.withEnrollmentCleanup(cleanup, {
                                cleanupMetadataIsDetached(transaction: transaction, recordID: transport.recordID,
                                    environment: transport.environment, cleanup: cleanup)
                            }) else { return .unavailable }
                            // Outside the read lock: recording takes the vault's write lock.
                            // A proof exists only once its durable receipt does.
                            try coordinator.recordEnrollmentSessionRevocation(cleanup, sessionKey: sessionKey)
                            return .confirmed(AccountEnrollmentSessionRevocation(accountManager: accountManager, coordinator: coordinator, cleanup: cleanup))
                        } catch { return .unavailable }
                    }
                }
            }
            let disposable = request.start(next: { result in
                guard !cancelled.with({ $0 }) else { return }
                _ = emitted.swap(true)
                subscriber.putNext(result)
            }, completed: {
                guard !cancelled.with({ $0 }) else { return }
                if !emitted.swap(true) { subscriber.putNext(.unavailable) }
                subscriber.putCompletion()
            })
            return ActionDisposable { _ = cancelled.swap(true); disposable.dispose() }
        }
    }
}
