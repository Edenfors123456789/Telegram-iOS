#if os(iOS)
import AccessModeCore

/// Main-process, initial-only owner migration. A successful legacy rewrap can precede
/// a failed Dual PIN file commit: publish its reference even then; the known new A
/// code still unlocks legacy protection and its original resource keys.
public final class DualPINLegacyMigration {
    private let legacy: PasscodeCredentialStore
    private let environment: PasscodeEnvironment

    public convenience init() { self.init(legacy: .shared, environment: .shared) }

    init(legacy: PasscodeCredentialStore, environment: PasscodeEnvironment) {
        self.legacy = legacy
        self.environment = environment
    }

    public func install(store: AccessCredentialStore, configuration: AccessConfiguration,
                        pinA: String, pinB: String, ownerSession: PasscodeSession?,
                        didCommitLegacyReference: (PasscodeCredentialReference) throws -> Void) throws -> PasscodeCredentialReference {
        try performInstall(store: store, configuration: configuration, pinA: pinA, pinB: pinB,
            ownerSession: ownerSession, didCommitLegacyReference: didCommitLegacyReference).reference
    }

    /// Lifecycle setup consumes only a successfully committed receipt, never an
    /// unlock/resource grant. The legacy reference is still acknowledged first.
    public func installForSetup(store: AccessCredentialStore, configuration: AccessConfiguration,
                               pinA: String, pinB: String, ownerSession: PasscodeSession?,
                               didCommitLegacyReference: (PasscodeCredentialReference) throws -> Void) throws -> AccessInitialSetupReceipt {
        try performInstall(store: store, configuration: configuration, pinA: pinA, pinB: pinB,
            ownerSession: ownerSession, didCommitLegacyReference: didCommitLegacyReference).receipt
    }

    private func performInstall(store: AccessCredentialStore, configuration: AccessConfiguration,
                                pinA: String, pinB: String, ownerSession: PasscodeSession?,
                                didCommitLegacyReference: (PasscodeCredentialReference) throws -> Void) throws -> (reference: PasscodeCredentialReference, receipt: AccessInitialSetupReceipt) {
        guard environment.isMainApp else { throw PasscodeError.authenticationRequired }
        var reference: PasscodeCredentialReference?
        let receipt = try store.initialize(configuration: configuration, pinA: pinA, pinB: pinB, prepareProtectedResources: {
            if let ownerSession {
                try ownerSession.require(scope: .settings, passcode: true)
                try self.legacy.validate(ownerSession, scope: .settings)
            } else {
                guard try self.legacy.protectionSettings().passcode == nil else { throw PasscodeError.authenticationRequired }
            }
            // Validate owner first, then deny every generic PIN/protection writer
            // before rewrap. Keep the latch across partial failure: authenticated
            // known-new-A retry uses these module-private initial-only methods.
            self.legacy.requireModePINManagement()
            let result = try self.legacy.setInitialModeOwnerPasscode(pinA, session: ownerSession)
            defer { result.session.invalidate() }
            reference = result.reference
            // This must reach AccountManager even if biometric cleanup or the access
            // file commit fails. Never silently restore a prior unsecured challenge.
            try didCommitLegacyReference(result.reference)
            // A stored legacy PIN may exist with resource protection turned off.
            // Dual PIN must not publish while that key remains accessible through
            // the ordinary unprotected-resource-session path.
            if try !self.legacy.protectionSettings().enabled {
                try self.legacy.enableInitialModeProtection(session: result.session)
            }
            try self.legacy.disableBiometrics(session: result.session)
        })
        guard let reference else { throw PasscodeError.unavailable }
        return (reference, receipt)
    }
}
#endif
