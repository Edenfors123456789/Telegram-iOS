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
        guard environment.isMainApp else { throw PasscodeError.authenticationRequired }
        var reference: PasscodeCredentialReference?
        try store.initialize(configuration: configuration, pinA: pinA, pinB: pinB, prepareProtectedResources: {
            if let ownerSession {
                try ownerSession.require(scope: .settings, passcode: true)
                try self.legacy.validate(ownerSession, scope: .settings)
            } else {
                guard try self.legacy.protectionSettings().passcode == nil else { throw PasscodeError.authenticationRequired }
            }
            let result = try self.legacy.setPasscodeWithSettingsSession(pinA, kind: .digits6, session: ownerSession)
            defer { result.session.invalidate() }
            reference = result.reference
            // This must reach AccountManager even if biometric cleanup or the access
            // file commit fails. Never silently restore a prior unsecured challenge.
            try didCommitLegacyReference(result.reference)
            try self.legacy.disableBiometrics(session: result.session)
        })
        guard let reference else { throw PasscodeError.unavailable }
        return reference
    }
}
#endif
