#if os(iOS)
import Foundation
import AccessModeCore

/// Main-only adapter. Caller covers/detaches before staging; no operation returns
/// an unlock session. AccountManager publication must be durably acknowledged.
public final class DualPINLegacyJournal {
    private let legacy: PasscodeCredentialStore
    private let environment: PasscodeEnvironment

    public convenience init() { self.init(legacy: .shared, environment: .shared) }
    init(legacy: PasscodeCredentialStore, environment: PasscodeEnvironment) {
        self.legacy = legacy
        self.environment = environment
    }

    @discardableResult public func stage(store: AccessCredentialStore, grant: AuthenticatedModeGrant,
                                         currentPIN: String, newPIN: String) throws -> UUID {
        guard environment.isMainApp else { throw PasscodeError.authenticationRequired }
        let context = try environment.sharedAccessGroup()
        let id = try store.beginOwnerPINChange(grant: grant, currentPIN: currentPIN, newPIN: newPIN) {
            let session = try self.legacy.verify(currentPIN, scope: .settings)
            defer { session.invalidate() }
            return try self.legacy.prepareOwnerPINRewrap(newPIN, session: session, context: context)
        }
        // Once the denied journal is durable, revoke legacy resource sessions too.
        PasscodeSession.invalidateAll()
        legacy.requireModePINManagement()
        return id
    }

    @discardableResult public func recover(store: AccessCredentialStore,
                                           didCommitLegacyReference: (PasscodeCredentialReference) throws -> Void) throws -> Bool {
        guard environment.isMainApp else { throw PasscodeError.authenticationRequired }
        legacy.requireModePINManagement()
        let context = try environment.sharedAccessGroup()
        return try store.resumeOwnerPINChange { prepared in
            let reference = try self.legacy.applyOwnerPINRewrap(prepared, context: context)
            try didCommitLegacyReference(reference)
        }
    }
}
#endif
