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
}

private final class NativeEnrollmentSessionKeySource: AccountEnrollmentSessionKeySource {
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
}

extension AccountEnrollmentBridge {
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
        let consumed = Atomic<Bool>(value: false)
        return Signal { subscriber in
            guard !consumed.swap(true) else {
                subscriber.putNext(false); subscriber.putCompletion()
                return EmptyDisposable
            }
            let cancelled = Atomic<Bool>(value: false)
            let metadata = URL(fileURLWithPath: accountManager.basePath).standardizedFileURL
            let expected = metadata.deletingLastPathComponent()
                .appendingPathComponent(accountRecordIdPathName(AccountRecordId(rawValue: source.recordID))).standardizedFileURL
            guard metadata.lastPathComponent == "accounts-metadata",
                  URL(fileURLWithPath: source.basePath).standardizedFileURL == expected else {
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
