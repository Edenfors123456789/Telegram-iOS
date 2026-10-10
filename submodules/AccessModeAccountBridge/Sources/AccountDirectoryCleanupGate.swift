import Foundation
import AccessModeCore

/// Starts denied, including before mode setup or if startup recovery fails.
/// It controls only unreferenced local directories, never server cleanup or UI.
public final class AccountDirectoryCleanupGate {
    private let mutex = NSLock()
    private var coordinator: AccessModeCoordinator?

    public init() {}

    public func configure(_ coordinator: AccessModeCoordinator) {
        mutex.lock(); self.coordinator = coordinator; mutex.unlock()
    }

    public func perform(recordID: Int64, _ body: () -> Bool) -> Bool {
        mutex.lock(); let current = coordinator; mutex.unlock()
        guard let current else { return false }
        do { return try current.withUnownedAccountDirectory(recordID: recordID, body) ?? false }
        catch { return false }
    }
}
