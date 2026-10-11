import Foundation
import CryptoKit
import AccessModeCore
import TelegramCore
import MtProtoKit
import SwiftSignalKit

protocol AccountEnrollmentSessionKeySource: AnyObject {
    var recordID: Int64 { get }
    var environment: AccessModeCore.AccountEnvironment { get }
    var basePath: String { get }
    func persistentFingerprint() -> AccountEnrollmentSessionKey?
    func persistentFingerprint(datacenterID: Int32) -> AccountEnrollmentSessionKey?
}

extension AccountEnrollmentSessionKeySource {
    func persistentFingerprint(datacenterID: Int32) -> AccountEnrollmentSessionKey? {
        guard let value = persistentFingerprint(), value.datacenterID == datacenterID else { return nil }
        return value
    }
}

final class NativeEnrollmentSessionKeySource: AccountEnrollmentSessionKeySource {
    let recordID: Int64
    let environment: AccessModeCore.AccountEnvironment
    let basePath: String
    let network: Network
    init(account: UnauthorizedAccount) {
        recordID = account.id.int64
        environment = account.testingEnvironment ? .test : .production
        basePath = account.basePath
        network = account.network
    }
    func persistentFingerprint() -> AccountEnrollmentSessionKey? {
        return AccountEnrollmentBridge.persistentFingerprint(datacenterID: network.datacenterId,
            authInfo: network.context.authInfoForDatacenter(withId: network.datacenterId, selector: .persistent))
    }
    func persistentFingerprint(datacenterID: Int32) -> AccountEnrollmentSessionKey? {
        AccountEnrollmentBridge.persistentFingerprint(datacenterID: Int(datacenterID),
            authInfo: network.context.authInfoForDatacenter(withId: Int(datacenterID), selector: .persistent))
    }
    init?(account: AccountResult) {
        switch account {
        case .upgrading: return nil
        case let .authorized(value):
            recordID = value.id.int64; environment = value.testingEnvironment ? .test : .production
            basePath = value.basePath; network = value.network
        case let .unauthorized(value):
            recordID = value.id.int64; environment = value.testingEnvironment ? .test : .production
            basePath = value.basePath; network = value.network
        }
    }
}

extension AccountEnrollmentBridge {
    /// A current observation, never RPC completion or data-access authority.
    public static func reconcileOriginalSessionKeys(account: AccountResult,
        accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        cleanup: AccountEnrollmentCleanupTicket) -> Signal<Bool, NoError> {
        guard let source = NativeEnrollmentSessionKeySource(account: account) else { return .single(false) }
        return reconcileOriginalSessionKeys(source: source, accountManager: accountManager, coordinator: coordinator, cleanup: cleanup)
    }

    static func reconcileOriginalSessionKeys(source: AccountEnrollmentSessionKeySource,
        accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        cleanup: AccountEnrollmentCleanupTicket) -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let cancelled = Atomic<Bool>(value: false)
            guard matchesNativeRoot(basePath: source.basePath, recordID: source.recordID, accountManager: accountManager) else {
                subscriber.putNext(false); subscriber.putCompletion()
                return EmptyDisposable
            }
            let disposable = accountManager.transaction { transaction -> Bool in
                guard !cancelled.with({ $0 }), hasOriginalSessionKeys(source: source, coordinator: coordinator, cleanup: cleanup) else { return false }
                do {
                    return try coordinator.withEnrollmentCleanup(cleanup) {
                        cleanupMetadataIsDetached(transaction: transaction, recordID: source.recordID,
                            environment: source.environment, cleanup: cleanup)
                    }
                } catch { return false }
            }.start(next: { result in
                if !cancelled.with({ $0 }) { subscriber.putNext(result) }
            }, completed: {
                if !cancelled.with({ $0 }) { subscriber.putCompletion() }
            })
            return ActionDisposable { _ = cancelled.swap(true); disposable.dispose() }
        }
    }

    static func hasOriginalSessionKeys(source: AccountEnrollmentSessionKeySource,
        coordinator: AccessModeCoordinator, cleanup: AccountEnrollmentCleanupTicket) -> Bool {
        guard source.recordID == cleanup.provisionalRecordID, source.environment == cleanup.environment else { return false }
        do {
            let saved = try coordinator.boundEnrollmentSessionKeys(cleanup)
            guard !saved.isEmpty, let main = source.persistentFingerprint(), saved.contains(main),
                  saved.allSatisfy({ source.persistentFingerprint(datacenterID: $0.datacenterID) == $0 }) else { return false }
            // Observe the context outside Core's file lock; never invert the
            // MTContext/Core lock ordering. Revalidate the owner after the read.
            return try coordinator.withEnrollmentCleanup(cleanup) { true }
        } catch { return false }
    }

    static func matchesNativeRoot(basePath: String, recordID: Int64,
        accountManager: AccountManager<TelegramAccountManagerTypes>) -> Bool {
        let metadata = URL(fileURLWithPath: accountManager.basePath).standardizedFileURL
        let expected = metadata.deletingLastPathComponent()
            .appendingPathComponent(accountRecordIdPathName(AccountRecordId(rawValue: recordID))).standardizedFileURL
        return metadata.lastPathComponent == "accounts-metadata" && URL(fileURLWithPath: basePath).standardizedFileURL == expected
    }

    static func cleanupMetadataIsDetached(transaction: AccountManagerModifier<TelegramAccountManagerTypes>,
        recordID: Int64, environment: AccessModeCore.AccountEnvironment, cleanup: AccountEnrollmentCleanupTicket) -> Bool {
        guard recordID == cleanup.provisionalRecordID, environment == cleanup.environment,
              transaction.getCurrentAuth()?.id.int64 != cleanup.provisionalRecordID else { return false }
        if let record = transaction.getRecords().first(where: { $0.id.int64 == cleanup.provisionalRecordID }) {
            let environments = record.attributes.compactMap { attribute -> Bool? in
                guard case let .environment(value) = attribute else { return nil }
                return value.environment == .test
            }
            guard environments.count <= 1, (environments.first ?? false) == (cleanup.environment == .test) else { return false }
        }
        return true
    }

    /// Persists evidence only; the result grants no authorization or display.
    public static func bindOriginalSessionKey(account: UnauthorizedAccount,
        accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        permit: AccountEnrollmentPermit, ticket: AccessTicket) -> Signal<Bool, NoError> {
        bindOriginalSessionKey(source: NativeEnrollmentSessionKeySource(account: account),
            accountManager: accountManager, coordinator: coordinator, permit: permit, ticket: ticket)
    }

    static func persistentFingerprint(datacenterID: Int, authInfo: MTDatacenterAuthInfo?) -> AccountEnrollmentSessionKey? {
        guard datacenterID > 0, datacenterID <= Int(Int32.max),
              let authInfo, authInfo.validUntilTimestamp == Int32.max,
              let raw = authInfo.authKey, raw.count == 256 else { return nil }
        return try? AccountEnrollmentSessionKey(datacenterID: Int32(datacenterID), digest: Data(SHA256.hash(data: raw)))
    }

    static func bindOriginalSessionKey(source: AccountEnrollmentSessionKeySource,
        accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        permit: AccountEnrollmentPermit, ticket: AccessTicket) -> Signal<Bool, NoError> {
        bindOriginalSessionKey(source: source, accountManager: accountManager, coordinator: coordinator,
            permit: permit, ticket: ticket, markAttempt: false)
    }

    /// Call, and wait for true, before every request that may authorize the
    /// provisional key (sign-in, sign-up, password, passkey, QR, payment, any
    /// reply that can carry `sentCodeSuccess`). Binds the account's current main
    /// key and marks it as attempted. False means: do not send.
    public static func prepareAuthorizationAttempt(account: UnauthorizedAccount,
        accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        permit: AccountEnrollmentPermit, ticket: AccessTicket) -> Signal<Bool, NoError> {
        prepareAuthorizationAttempt(source: NativeEnrollmentSessionKeySource(account: account), accountManager: accountManager,
            coordinator: coordinator, permit: permit, ticket: ticket)
    }

    static func prepareAuthorizationAttempt(source: AccountEnrollmentSessionKeySource,
        accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        permit: AccountEnrollmentPermit, ticket: AccessTicket) -> Signal<Bool, NoError> {
        bindOriginalSessionKey(source: source, accountManager: accountManager, coordinator: coordinator,
            permit: permit, ticket: ticket, markAttempt: true)
    }

    private static func bindOriginalSessionKey(source: AccountEnrollmentSessionKeySource,
        accountManager: AccountManager<TelegramAccountManagerTypes>, coordinator: AccessModeCoordinator,
        permit: AccountEnrollmentPermit, ticket: AccessTicket, markAttempt: Bool) -> Signal<Bool, NoError> {
        let consumed = Atomic<Bool>(value: false)
        return Signal { subscriber in
            guard !consumed.swap(true) else {
                subscriber.putNext(false); subscriber.putCompletion()
                return EmptyDisposable
            }
            let cancelled = Atomic<Bool>(value: false)
            guard matchesNativeRoot(basePath: source.basePath, recordID: source.recordID, accountManager: accountManager) else {
                subscriber.putNext(false); subscriber.putCompletion()
                return EmptyDisposable
            }
            let disposable = accountManager.transaction { transaction -> Bool in
                guard !cancelled.with({ $0 }), let auth = transaction.getCurrentAuth(),
                      auth.id.int64 == source.recordID,
                      !transaction.getRecords().contains(where: { $0.id == auth.id }) else { return false }
                let environments = auth.attributes.compactMap { attribute -> Bool? in
                    guard case let .environment(value) = attribute else { return nil }
                    return value.environment == .test
                }
                guard environments.count <= 1,
                      (environments.first ?? false) == (source.environment == .test),
                      let fingerprint = source.persistentFingerprint(), !cancelled.with({ $0 }) else { return false }
                do {
                    // This idempotent check ties the caller's actual native record
                    // to the permit before it can supply that record's key digest.
                    try coordinator.bindEnrollment(permit, provisionalRecordID: source.recordID,
                        environment: source.environment, ticket: ticket)
                    guard !cancelled.with({ $0 }) else {
                        try? coordinator.cancelEnrollment(permit, ticket: ticket)
                        return false
                    }
                    try coordinator.bindEnrollmentSessionKey(permit, sessionKey: fingerprint, ticket: ticket)
                    guard !cancelled.with({ $0 }) else {
                        try? coordinator.cancelEnrollment(permit, ticket: ticket)
                        return false
                    }
                    guard source.persistentFingerprint() == fingerprint else {
                        try? coordinator.lock()
                        return false
                    }
                    if markAttempt {
                        // Only a key confirmed current is marked: a stale mark is a
                        // key the logout transport can no longer reach.
                        try coordinator.markEnrollmentAuthorizationAttempt(permit, sessionKey: fingerprint, ticket: ticket)
                        guard source.persistentFingerprint() == fingerprint else {
                            try? coordinator.lock()
                            return false
                        }
                    }
                    return true
                } catch { return false }
            }.start(next: { result in
                if !cancelled.with({ $0 }) { subscriber.putNext(result) }
            }, completed: {
                if !cancelled.with({ $0 }) { subscriber.putCompletion() }
            })
            return ActionDisposable { _ = cancelled.swap(true); disposable.dispose() }
        }
    }
}

