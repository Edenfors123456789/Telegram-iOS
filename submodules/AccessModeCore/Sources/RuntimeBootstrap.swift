import Foundation

/// Startup may continue ordinary initial setup only after a successful absent-vault
/// check. A factory, protected-data, Keychain or configuration failure is denied.
/// This result is process-local and must never be persisted as an unlock decision.
public enum AccessRuntimeBootstrap {
    case unconfigured
    case configured(AccessCredentialStore)
    case unavailable

    public var requiresModeAuthentication: Bool {
        if case .unconfigured = self { return false }
        return true
    }

    public static func inspect(_ makeStore: () throws -> AccessCredentialStore) -> Self {
        do {
            let store = try makeStore()
            return try store.isConfigured() ? .configured(store) : .unconfigured
        } catch { return .unavailable }
    }
}
