import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import AccessModeCore

/// Push is disabled in both modes (docs/dual-pin/PUSH.md). Nothing registers; this cancels on
/// the server what earlier builds registered, one account and token type at a time, and drops a
/// ledger entry only on the server's answer. The tokens it is given are used for nothing else.
final class PushRegistrationCleanupRunner {
    private static let storageKey = "dualPinPushRegistrationCleanup.v1"

    private var ledger: PushRegistrationCleanupLedger
    private var inFlight = Set<String>()
    private let disposables = DisposableSet()
    private let finished: () -> Void

    /// Nil when nothing is pending; `finished` is not called then.
    static func make(signedInAccounts: Set<Int64>, finished: @escaping () -> Void) -> PushRegistrationCleanupRunner? {
        let ledger = PushRegistrationCleanupLedger.load(UserDefaults.standard.data(forKey: PushRegistrationCleanupRunner.storageKey), signedInAccounts: signedInAccounts)
        PushRegistrationCleanupRunner.store(ledger)
        if ledger.isEmpty {
            return nil
        }
        return PushRegistrationCleanupRunner(ledger: ledger, finished: finished)
    }

    private init(ledger: PushRegistrationCleanupLedger, finished: @escaping () -> Void) {
        self.ledger = ledger
        self.finished = finished
    }

    deinit {
        self.disposables.dispose()
    }

    private static func store(_ ledger: PushRegistrationCleanupLedger) {
        if let data = try? ledger.encoded() {
            UserDefaults.standard.set(data, forKey: PushRegistrationCleanupRunner.storageKey)
        }
    }

    /// Cancels `type`'s registrations for the active accounts that still have one, whenever a
    /// token or the accounts change. Main queue.
    func start(type: PushRegistrationCleanupLedger.TokenType, token: Signal<Data?, NoError>, activeAccounts: Signal<[AccountContext], NoError>) {
        self.disposables.add((combineLatest(queue: .mainQueue(), activeAccounts, token)
        |> deliverOnMainQueue).start(next: { [weak self] accounts, token in
            guard let self, let token else {
                return
            }
            for context in accounts {
                self.cancel(type: type, token: token, context: context, accounts: accounts)
            }
        }))
    }

    private func cancel(type: PushRegistrationCleanupLedger.TokenType, token: Data, context: AccountContext, accounts: [AccountContext]) {
        let account = context.account.id.int64
        let key = "\(account)/\(type.rawValue)"
        guard self.ledger.pendingTypes(account: account).contains(type), !self.inFlight.contains(key) else {
            return
        }
        self.inFlight.insert(key)
        let otherAccountUserIds = accounts.filter {
            $0.account.testingEnvironment == context.account.testingEnvironment && $0.account.peerId != context.account.peerId
        }.map { $0.account.peerId.id }
        let tokenType: NotificationTokenType
        switch type {
        case .aps:
            tokenType = .aps(encrypt: false)
        case .voip:
            tokenType = .voip
        }
        // A non-primary account is otherwise not connected, and its request would wait for the
        // user to switch to it.
        let keepConnected = context.account.addExplicitImportantTask()
        self.disposables.add((context.engine.accountData.unregisterNotificationToken(token: token, type: tokenType, otherAccountUserIds: otherAccountUserIds)
        |> afterDisposed {
            keepConnected.dispose()
        }
        |> deliverOnMainQueue).start(next: { [weak self] acknowledged in
            guard let self else {
                return
            }
            self.inFlight.remove(key)
            Logger.shared.log("PushCleanup", "account \(account) \(type.rawValue): \(acknowledged ? "cancelled" : "not confirmed, kept")")
            guard acknowledged else {
                return
            }
            self.ledger.acknowledge(account: account, type: type)
            PushRegistrationCleanupRunner.store(self.ledger)
            if self.ledger.isEmpty {
                self.finished()
            }
        }))
    }
}
