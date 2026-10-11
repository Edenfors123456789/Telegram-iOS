import Foundation

/// What the share extension may show after a PIN (plan §7: its own PIN, the shared access
/// policy): the mode's accounts in raw order, its selected account first in the sheet, and per
/// account the chats its lists must leave out. The extension registers those in its own Postbox
/// before any list is built; the main app's registrations do not reach another process.
public struct ShareAccessScope: Equatable {
    public let mode: AccessMode
    /// Account record ids the sheet may use, in raw display order.
    public let recordIDs: [Int64]
    public let primaryRecordID: Int64
    /// Chats hidden from lists, by account record id; only accounts that have any.
    public let hiddenChats: [Int64: [ChatIdentity]]
    /// B keeps its own recent searches apart from A's.
    public var redirectsRecentSearches: Bool { mode == .b }
}

extension AccessModePolicy {
    /// Throws when the selected account is not among `observed` (no fallback to another
    /// account) or when a hidden chat cannot be named as a Postbox peer id (it could not be
    /// left out, so nothing may be shown).
    public func shareScope(observed: [ObservedAccount]) throws -> ShareAccessScope {
        let projection = try projectAccounts(observed)
        guard let primary = projection.primary else { throw AccessError.unavailable }
        var hiddenChats: [Int64: [ChatIdentity]] = [:]
        for account in projection.accounts {
            let chats = undiscoverableChats(of: account)
            guard chats.allSatisfy({ $0.peerID <= 0x00ff_ffff_ffff_ffff }) else { throw AccessError.unavailable }
            if !chats.isEmpty {
                hiddenChats[account.recordID] = chats
            }
        }
        return ShareAccessScope(mode: mode, recordIDs: projection.accounts.map(\.recordID), primaryRecordID: primary.recordID, hiddenChats: hiddenChats)
    }
}
