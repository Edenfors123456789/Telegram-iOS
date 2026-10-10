import Foundation
import SwiftSignalKit

/// Synchronous permission callback. Body must finish while ownership is held;
/// never enqueue a deletion using a successful earlier permission snapshot.
public typealias AccountDirectoryDeletionGuard = (AccountRecordId, () -> Bool) -> Bool

/// Local orphan cleanup only. Its result is not server/session cleanup proof.
public func removeUnreferencedAccountDirectory(accountManager: AccountManager<TelegramAccountManagerTypes>, rootPath: String, directoryName: String,
    deletionGuard: @escaping AccountDirectoryDeletionGuard) -> Signal<Bool, NoError> {
    guard directoryName.hasPrefix("account-"), let raw = UInt64(directoryName.dropFirst(8)), directoryName == "account-\(raw)" else { return .single(false) }
    let id = AccountRecordId(rawValue: Int64(bitPattern: raw))
    let root = URL(fileURLWithPath: rootPath).standardizedFileURL
    let metadata = URL(fileURLWithPath: accountManager.basePath).standardizedFileURL
    guard metadata.lastPathComponent == "accounts-metadata", metadata.deletingLastPathComponent() == root else { return .single(false) }
    let directory = root.appendingPathComponent(directoryName)
    return accountManager.transaction { transaction -> Bool in
        // The account view used to discover candidates can be stale by now.
        // Retain every live raw record, including temporary and current auth.
        guard transaction.getCurrentAuth()?.id != id,
              !transaction.getRecords().contains(where: { $0.id == id }) else { return false }
        return deletionGuard(id) {
            // Evaluate paths inside both the metadata transaction and the
            // caller's ownership lock. Never follow an account/root symlink.
            let manager = FileManager.default
            for path in [root, metadata, directory] {
                guard let attributes = try? manager.attributesOfItem(atPath: path.path),
                      let type = attributes[.type] as? FileAttributeType,
                      type == .typeDirectory else { return false }
            }
            guard root.resolvingSymlinksInPath() == root else { return false }
            do { try manager.removeItem(at: directory); return true }
            catch { return false }
        }
    }
}
