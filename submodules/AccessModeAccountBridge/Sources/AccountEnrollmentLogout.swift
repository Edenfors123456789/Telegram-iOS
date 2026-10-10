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
    func logout() -> Signal<AccountEnrollmentLogoutReply, NoError>
}

extension AccountEnrollmentLogoutTransport {
    var hasOriginalAuthorizationBinding: Bool { false }
    var isOriginalSessionCurrent: Bool { false }
}

private final class TelegramEnrollmentLogoutTransport: AccountEnrollmentLogoutTransport {
    let recordID: Int64
    let environment: AccessModeCore.AccountEnvironment
    let network: Network
    let stopServiceTasks: () -> Void
    init(recordID: Int64, environment: AccessModeCore.AccountEnvironment, network: Network, stopServiceTasks: @escaping () -> Void) {
        self.recordID = recordID; self.environment = environment
        self.network = network; self.stopServiceTasks = stopServiceTasks
    }
    func logout() -> Signal<AccountEnrollmentLogoutReply, NoError> {
        return Signal { subscriber in
            self.stopServiceTasks()
            return (self.network.request(Api.functions.auth.logOut(), automaticFloodWait: false)
            |> map { _ -> AccountEnrollmentLogoutReply in .loggedOut }
            |> `catch` { _ -> Signal<AccountEnrollmentLogoutReply, NoError> in
                // Errors cannot prove our original key was revoked if a fresh
                // key was created after storage loss. Retain ownership instead.
                return .single(.unavailable)
            }).start(next: { subscriber.putNext($0) }, completed: { subscriber.putCompletion() })
        }
    }
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
        let transport: TelegramEnrollmentLogoutTransport
        let basePath: String
        switch account {
        case .upgrading: return .single(.unavailable)
        case let .authorized(value):
            basePath = value.basePath
            transport = TelegramEnrollmentLogoutTransport(recordID: value.id.int64, environment: value.testingEnvironment ? .test : .production,
                network: value.network, stopServiceTasks: { value.shouldBeServiceTaskMaster.set(.single(.never)) })
        case let .unauthorized(value):
            basePath = value.basePath
            transport = TelegramEnrollmentLogoutTransport(recordID: value.id.int64, environment: value.testingEnvironment ? .test : .production,
                network: value.network, stopServiceTasks: { value.shouldBeServiceTaskMaster.set(.single(.never)) })
        }
        let metadata = URL(fileURLWithPath: accountManager.basePath).standardizedFileURL
        let expected = metadata.deletingLastPathComponent().appendingPathComponent(accountRecordIdPathName(AccountRecordId(rawValue: transport.recordID))).standardizedFileURL
        guard metadata.lastPathComponent == "accounts-metadata", URL(fileURLWithPath: basePath).standardizedFileURL == expected else {
            return .single(.unavailable)
        }
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
                guard allowed, !cancelled.with({ $0 }), transport.isOriginalSessionCurrent else { return .single(.unavailable) }
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
                            return try coordinator.withEnrollmentCleanup(cleanup) {
                                guard cleanupMetadataIsDetached(transaction: transaction, recordID: transport.recordID,
                                    environment: transport.environment, cleanup: cleanup) else { return .unavailable }
                                return .confirmed(AccountEnrollmentSessionRevocation(accountManager: accountManager, coordinator: coordinator, cleanup: cleanup))
                            }
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
