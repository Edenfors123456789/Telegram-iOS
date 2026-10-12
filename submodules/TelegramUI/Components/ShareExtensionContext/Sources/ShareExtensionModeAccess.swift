import Foundation
import AccessModeCore
import PasscodeCore
import Postbox
import SwiftSignalKit
import TelegramCore

/// Dual PIN in the share extension (plan §7, docs/dual-pin/EXTERNAL.md): once the access vault
/// is configured, the sheet opens only with PIN A or PIN B, verified against the same vault as
/// the app through an extension coordinator (it never locks or unlocks the app), and shows only
/// that mode's accounts and lists. The legacy passcode (PIN A's copy) no longer opens it.
enum ShareExtensionModeAccess {
    /// The app's vault, opened the way `AppDelegate` opens it.
    static func inspect(rootPath: String, baseAppBundleId: String) -> AccessRuntimeBootstrap {
        return AccessRuntimeBootstrap.inspect {
            let group = try PasscodeEnvironment.shared.sharedAccessGroup()
            let key = try KeychainAccessDeviceKey(service: baseAppBundleId + ".dual-pin.v1", accessGroup: group)
            return try AccessCredentialStore(directory: URL(fileURLWithPath: rootPath).appendingPathComponent("dual-pin-access", isDirectory: true),
                namespace: baseAppBundleId + ":" + group, keyProvider: key)
        }
    }

    static func observedAccount(recordId: AccountRecordId, accountPeerId: PeerId, records: AccountRecordsView<TelegramAccountManagerTypes>) -> ObservedAccount {
        var isTest = false
        if let record = records.records.first(where: { $0.id == recordId }) {
            for attribute in record.attributes {
                if case let .environment(value) = attribute, value.environment == .test {
                    isTest = true
                }
            }
        }
        return ObservedAccount(environment: isTest ? .test : .production, recordID: recordId.int64,
            userNamespace: accountPeerId.namespace._internalGetInt32Value(), userID: accountPeerId.id._internalGetInt64Value())
    }

    /// Leaves `scope`'s hidden chats out of every list, search and recents of `postbox` and,
    /// in B, gives the sheet B's own recent searches. Held for the extension's lifetime.
    static func register(scope: ShareAccessScope, recordId: AccountRecordId, postbox: Postbox) -> Disposable {
        let disposables = DisposableSet()
        if scope.redirectsRecentSearches {
            disposables.add(addRestrictedModeListRedirections(postbox: postbox))
        }
        if let chats = scope.hiddenChats[recordId.int64], !chats.isEmpty {
            let peerIds = chats.map { PeerId(namespace: ._internalFromInt32Value($0.peerNamespace), id: ._internalFromInt64Value($0.peerID)) }
            disposables.add(postbox.addHiddenChatIds(peerIds: peerIds))
            // Nothing of a hidden chat's history is shown here (a topic list, say).
            let windowStart = Int32(max(0, Int64(Date().timeIntervalSince1970) - RestrictedTranscriptStore.window))
            for peerId in peerIds {
                disposables.add(postbox.addHistoryRestriction(peerId: peerId, MessageHistoryRestriction(boundary: nil, windowStart: windowStart,
                    outgoingGloballyUniqueIds: [], deletedMessageIds: [], excludedGlobalTags: [.Calls, .MissedCalls])))
            }
        }
        return disposables
    }
}
