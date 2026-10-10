import Foundation
import AccessModeCore
import TelegramCore
import MtProtoKit
import SwiftSignalKit

/// Internal native request boundary; fake RPC closures exist only in tests.
final class ScopedEnrollmentLogoutTransport: AccountEnrollmentLogoutTransport {
    let source: AccountEnrollmentSessionKeySource
    let accountManager: AccountManager<TelegramAccountManagerTypes>
    let coordinator: AccessModeCoordinator
    let cleanup: AccountEnrollmentCleanupTicket
    let engineKind: () -> NetworkEngineKind
    let stopServiceTasks: () -> Void
    let request: (NetworkRequestAuthKeyScope) -> Signal<Void, MTRpcError>
    let originalMain: AccountEnrollmentSessionKey?
    private let consumed = Atomic<Bool>(value: false)
    var recordID: Int64 { source.recordID }
    var environment: AccessModeCore.AccountEnvironment { source.environment }
    var revokedSessionKey: AccountEnrollmentSessionKey? { originalMain }

    init(source: AccountEnrollmentSessionKeySource, accountManager: AccountManager<TelegramAccountManagerTypes>,
        coordinator: AccessModeCoordinator, cleanup: AccountEnrollmentCleanupTicket,
        engineKind: @escaping () -> NetworkEngineKind, stopServiceTasks: @escaping () -> Void,
        request: @escaping (NetworkRequestAuthKeyScope) -> Signal<Void, MTRpcError>) {
        self.source = source; self.accountManager = accountManager; self.coordinator = coordinator; self.cleanup = cleanup
        self.engineKind = engineKind; self.stopServiceTasks = stopServiceTasks; self.request = request
        originalMain = source.persistentFingerprint()
    }
    var isOriginalSessionCurrent: Bool {
        guard let originalMain, engineKind() == .mtProtoKit,
              AccountEnrollmentBridge.matchesNativeRoot(basePath: source.basePath, recordID: source.recordID, accountManager: accountManager),
              source.persistentFingerprint() == originalMain else { return false }
        return AccountEnrollmentBridge.hasOriginalSessionKeys(source: source, coordinator: coordinator, cleanup: cleanup)
    }
    func logout() -> Signal<AccountEnrollmentLogoutReply, NoError> {
        return Signal { subscriber in
            guard !self.consumed.swap(true), self.isOriginalSessionCurrent, let original = self.originalMain else {
                subscriber.putNext(.unavailable); subscriber.putCompletion()
                return EmptyDisposable
            }
            let scope = NetworkRequestAuthKeyScope(datacenterId: original.datacenterID, permanentKeyDigest: original.digest)
            self.stopServiceTasks()
            // Task stopping can invoke synchronous callbacks. Revalidate after
            // it, without holding the Core vault lock through a network enqueue.
            guard self.isOriginalSessionCurrent else {
                subscriber.putNext(.unavailable); subscriber.putCompletion()
                return EmptyDisposable
            }
            return (self.request(scope)
            |> map { _ -> AccountEnrollmentLogoutReply in .loggedOut }
            |> `catch` { _ -> Signal<AccountEnrollmentLogoutReply, NoError> in
                // Even a protected PFS request's 401/406 can describe a temporary
                // key. It cannot prove the original permanent session inactive.
                return .single(.unavailable)
            }).start(next: { subscriber.putNext($0) }, completed: { subscriber.putCompletion() })
        }
    }
}
