import Foundation
import Darwin

public struct AccessClockSnapshot {
    public let bootID: String
    public let uptime: TimeInterval

    public init(bootID: String, uptime: TimeInterval) {
        self.bootID = bootID
        self.uptime = uptime
    }

    public static func system() throws -> AccessClockSnapshot {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { throw AccessError.unavailable }
        return AccessClockSnapshot(bootID: "\(boot.tv_sec):\(boot.tv_usec)", uptime: ProcessInfo.processInfo.systemUptime)
    }

    func validate() throws {
        guard !bootID.isEmpty, uptime.isFinite, uptime >= 0 else { throw AccessError.unavailable }
    }
}

enum AccessGrantPurpose { case access, pinChange }

/// Proof of this store instance's completed initial file commit. No data authority.
public struct AccessInitialSetupReceipt {
    let issuer: UUID
    let installation: UUID
    let configurationRevision: UInt64
    let a: UUID
    let b: UUID
}

public struct AuthenticatedModeGrant {
    public let mode: AccessMode
    let issuer: UUID
    let configurationRevision: UInt64
    let credentialID: UUID
    let credentialRevision: UInt64
    let revocation: UInt64
    let purpose: AccessGrantPurpose
}

struct PINCredential: Codable {
    let mode: AccessMode
    let id: UUID
    let revision: UInt64
    let salt: Data
    let iterations: Int
    let proof: Data

    var context: String { "telegram.dual-pin.credential.v1:\(mode.rawValue):\(id.uuidString):\(revision)" }

    func validate(expectedMode: AccessMode) throws {
        guard mode == expectedMode, revision > 0, salt.count == 16, proof.count == 60,
              (AccessCrypto.minimumIterations ... AccessCrypto.maximumIterations).contains(iterations) else { throw AccessError.corrupt }
    }

    static func create(mode: AccessMode, pin: String, deviceKey: Data, iterations: Int, revision: UInt64 = 1) throws -> PINCredential {
        let id = UUID()
        let salt = try AccessCrypto.random(16)
        var derived = try AccessCrypto.derive(pin, deviceKey: deviceKey, salt: salt, iterations: iterations)
        defer { derived.resetBytes(in: 0 ..< derived.count) }
        let context = "telegram.dual-pin.credential.v1:\(mode.rawValue):\(id.uuidString):\(revision)"
        return PINCredential(mode: mode, id: id, revision: revision, salt: salt, iterations: iterations,
                             proof: try AccessCrypto.seal(AccessCrypto.random(32), key: derived, context: context))
    }

    func matches(_ pin: String, deviceKey: Data) throws -> Bool {
        var derived = try AccessCrypto.derive(pin, deviceKey: deviceKey, salt: salt, iterations: iterations)
        defer { derived.resetBytes(in: 0 ..< derived.count) }
        guard var value = try? AccessCrypto.open(proof, key: derived, context: context) else { return false }
        defer { value.resetBytes(in: 0 ..< value.count) }
        return value.count == 32
    }
}

struct PINAttemptBudget: Codable {
    var failures = 0
    var bootID: String?
    var deadline: TimeInterval?

    func validate() throws {
        guard (0 ... 6).contains(failures),
              (failures < 6 && bootID == nil && deadline == nil) ||
                (failures == 6 && !(bootID ?? "").isEmpty && deadline?.isFinite == true && deadline! >= 0) else { throw AccessError.corrupt }
    }

    mutating func eligible(at clock: AccessClockSnapshot) -> Bool {
        guard failures >= 6 else { return true }
        // A reboot must not clear a cooldown. Start a fresh full delay in the new boot.
        if bootID != clock.bootID { bootID = clock.bootID; deadline = clock.uptime + 60 }
        return clock.uptime >= (deadline ?? .infinity)
    }

    mutating func fail(at clock: AccessClockSnapshot) {
        failures = min(6, failures + 1)
        if failures == 6 { bootID = clock.bootID; deadline = clock.uptime + 60 }
    }
}

struct AccessVaultState: Codable {
    var version: Int
    var configuration: AccessConfiguration
    var a: PINCredential
    var b: PINCredential
    var attemptsA: PINAttemptBudget
    var attemptsB: PINAttemptBudget
    var revocation: UInt64
    var pendingEnrollment: PendingAccountEnrollment? = nil
    var pendingOwnerPINChange: PendingOwnerPINChange? = nil

    func validate() throws {
        guard version == 1 || version == 2 else { throw AccessError.unsupportedVersion }
        try configuration.validate()
        try a.validate(expectedMode: .a)
        try b.validate(expectedMode: .b)
        try attemptsA.validate()
        try attemptsB.validate()
        guard a.id != b.id, a.salt != b.salt, revocation > 0 else { throw AccessError.corrupt }
        if let pendingEnrollment {
            guard pendingEnrollment.revocation == revocation,
                  pendingEnrollment.configurationRevision == configuration.revision else { throw AccessError.corrupt }
        }
        if let pendingOwnerPINChange {
            guard version == 2, pendingEnrollment == nil else { throw AccessError.corrupt }
            try pendingOwnerPINChange.validate(state: self)
        }
    }

    func require(_ grant: AuthenticatedModeGrant, issuer: UUID, permitsPINChange: Bool = false) throws {
        try validate()
        guard pendingOwnerPINChange == nil else { throw AccessError.unavailable }
        guard grant.purpose == .access || (permitsPINChange && grant.purpose == .pinChange) else { throw AccessError.authenticationRequired }
        let credential = grant.mode == .a ? a : b
        guard grant.issuer == issuer, grant.configurationRevision == configuration.revision,
              grant.credentialID == credential.id, grant.credentialRevision == credential.revision,
              grant.revocation == revocation else { throw AccessError.staleAuthorization }
    }
}

public final class AccessCredentialStore {
    let issuer = UUID()
    let file: EncryptedAccessFile<AccessVaultState>
    private let iterations: Int
    private let clock: () throws -> AccessClockSnapshot

    public init(directory: URL, namespace: String, keyProvider: AccessDeviceKeyProvider,
                iterations: Int? = nil, clock: @escaping () throws -> AccessClockSnapshot = AccessClockSnapshot.system) throws {
        let count = iterations ?? AccessCrypto.calibratedIterations()
        guard (AccessCrypto.minimumIterations ... AccessCrypto.maximumIterations).contains(count) else { throw AccessError.invalidConfiguration }
        self.iterations = count
        self.clock = clock
        self.file = try EncryptedAccessFile(directory: directory, namespace: namespace, keyProvider: keyProvider)
    }

    /// Stage-3 migration must authenticate the legacy owner before this initial-only operation.
    /// An existing, corrupt or unsupported vault cannot be replaced through this method.
    @discardableResult
    public func initialize(configuration: AccessConfiguration, pinA: String, pinB: String,
                           prepareProtectedResources: () throws -> Void = {}) throws -> AccessInitialSetupReceipt {
        try configuration.validate()
        guard Self.validPIN(pinA), Self.validPIN(pinB) else { throw AccessError.invalidPIN }
        guard pinA != pinB else { throw AccessError.identicalPINs }
        return try file.transaction(allowInitialization: true) { state, key in
            guard state == nil else { throw AccessError.alreadyConfigured }
            let initial = AccessVaultState(version: 1, configuration: configuration,
                a: try PINCredential.create(mode: .a, pin: pinA, deviceKey: key, iterations: self.iterations),
                b: try PINCredential.create(mode: .b, pin: pinB, deviceKey: key, iterations: self.iterations),
                attemptsA: PINAttemptBudget(), attemptsB: PINAttemptBudget(), revocation: 1)
            try initial.validate()
            // Under the initial-only file lock, after validation/crypto and before
            // publication. The owner adapter must preserve legacy resource keys.
            try prepareProtectedResources()
            state = initial
            return AccessInitialSetupReceipt(issuer: issuer, installation: configuration.installation,
                configurationRevision: configuration.revision, a: initial.a.id, b: initial.b.id)
        }
    }

    public func finishInitialSetup(_ receipt: AccessInitialSetupReceipt) throws {
        guard receipt.issuer == issuer else { throw AccessError.staleAuthorization }
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.validate()
            guard state.version == 1, state.configuration.installation == receipt.installation,
                  state.configuration.revision == receipt.configurationRevision,
                  state.a.id == receipt.a, state.b.id == receipt.b,
                  state.revocation == 1, state.pendingEnrollment == nil,
                  state.pendingOwnerPINChange == nil else { throw AccessError.staleAuthorization }
            state.revocation += 1
            stored = state
        }
    }

    public func isConfigured() throws -> Bool {
        do { return try file.withReadState { state in try state.validate(); return true } }
        catch AccessError.authenticationRequired { return false }
    }

    public func authenticate(pin: String) throws -> AuthenticatedModeGrant {
        guard Self.validPIN(pin) else { throw AccessError.invalidPIN }
        let result: Result<AuthenticatedModeGrant, AccessError> = try file.transaction { stored, key in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.validate()
            guard state.pendingOwnerPINChange == nil else { throw AccessError.unavailable }
            let now = try self.clock()
            try now.validate()
            let eligibleA = state.attemptsA.eligible(at: now)
            let eligibleB = state.attemptsB.eligible(at: now)
            // Always derive/check both records; no early return indicating the matched role.
            let matchesA = try state.a.matches(pin, deviceKey: key)
            let matchesB = try state.b.matches(pin, deviceKey: key)
            guard !(matchesA && matchesB) else { throw AccessError.corrupt }
            let mode: AccessMode? = matchesA && eligibleA ? .a : (matchesB && eligibleB ? .b : nil)
            let outcome: Result<AuthenticatedModeGrant, AccessError>
            if let mode {
                if mode == .a { state.attemptsA = PINAttemptBudget() } else { state.attemptsB = PINAttemptBudget() }
                outcome = .success(self.grant(mode: mode, state: state))
            } else {
                // A known but temporarily blocked PIN must not count as a wrong guess for B.
                if !matchesA && !matchesB {
                    if eligibleA { state.attemptsA.fail(at: now) }
                    if eligibleB { state.attemptsB.fail(at: now) }
                }
                outcome = .failure(!eligibleA && !eligibleB ? .cooldown : .invalidPIN)
            }
            stored = state
            return outcome
        }
        // Persistence failure throws before a grant leaves the store.
        return try result.get()
    }

    public func changePIN(grant: AuthenticatedModeGrant, currentPIN: String, newPIN: String) throws {
        // A wraps Telegram's protected-resource key as well as this credential.
        // Its only replacement path is the durable owner journal below.
        guard grant.mode == .b else { throw AccessError.authenticationRequired }
        guard Self.validPIN(newPIN) else { throw AccessError.invalidPIN }
        let current = try authenticate(pin: currentPIN)
        guard current.mode == grant.mode else { throw AccessError.authenticationRequired }
        try file.transaction { stored, key in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: self.issuer, permitsPINChange: true)
            try state.require(current, issuer: self.issuer)
            let other = grant.mode == .a ? state.b : state.a
            guard try !other.matches(newPIN, deviceKey: key) else { throw AccessError.identicalPINs }
            let old = grant.mode == .a ? state.a : state.b
            guard old.revision < UInt64.max, state.revocation < UInt64.max else { throw AccessError.corrupt }
            let replacement = try PINCredential.create(mode: grant.mode, pin: newPIN, deviceKey: key,
                                                       iterations: self.iterations, revision: old.revision + 1)
            if grant.mode == .a { state.a = replacement } else { state.b = replacement }
            state.revocation += 1
            state.pendingEnrollment = nil
            stored = state
        }
    }

    /// Attach the cover and detach the root first. Preparation must return an
    /// authenticated rewrap plan without modifying the other credential store.
    /// Expensive crypto and I/O belong off the UI thread. No grant is returned.
    public func beginOwnerPINChange(grant: AuthenticatedModeGrant, currentPIN: String, newPIN: String,
                                    prepareProtectedResources: () throws -> Data) throws -> UUID {
        guard grant.mode == .a else { throw AccessError.authenticationRequired }
        guard Self.validPIN(newPIN) else { throw AccessError.invalidPIN }
        let current = try authenticate(pin: currentPIN)
        guard current.mode == .a else { throw AccessError.authenticationRequired }
        return try file.transaction { stored, key in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: issuer, permitsPINChange: true)
            try state.require(current, issuer: issuer)
            guard try !state.b.matches(newPIN, deviceKey: key) else { throw AccessError.identicalPINs }
            guard state.a.revision < UInt64.max, state.revocation < UInt64.max else { throw AccessError.corrupt }
            let replacement = try PINCredential.create(mode: .a, pin: newPIN, deviceKey: key,
                iterations: iterations, revision: state.a.revision + 1)
            let plan = try prepareProtectedResources()
            guard !plan.isEmpty, plan.count <= PendingOwnerPINChange.maximumPlanBytes else { throw AccessError.invalidConfiguration }
            let pending = PendingOwnerPINChange(id: UUID(), credentialID: state.a.id,
                configurationRevision: state.configuration.revision, replacement: replacement, preparedResources: plan)
            // Older readers must reject this schema, including after finalization.
            // Keep the same file path: never interpret a new-schema vault as absent.
            state.version = 2
            state.revocation += 1
            state.pendingEnrollment = nil
            state.pendingOwnerPINChange = pending
            try state.validate()
            stored = state
            return pending.id
        }
    }

    public func hasPendingOwnerPINChange() throws -> Bool {
        try file.withReadState { state in try state.validate(); return state.pendingOwnerPINChange != nil }
    }

    /// Main-process adapter only. Under the vault lock, idempotently apply the
    /// prepared resource wrapping AND persist its AccountManager reference before
    /// returning. Any error leaves a denied, replayable journal. Recovery never
    /// authenticates the user or publishes a root; a fresh PIN is still required.
    @discardableResult public func resumeOwnerPINChange(applyProtectedResources: (Data) throws -> Void) throws -> Bool {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.validate()
            guard let pending = state.pendingOwnerPINChange else { return false }
            guard state.revocation < UInt64.max else { throw AccessError.corrupt }
            try applyProtectedResources(pending.preparedResources)
            state.a = pending.replacement
            state.attemptsA = PINAttemptBudget()
            state.pendingOwnerPINChange = nil
            state.revocation += 1
            try state.validate()
            stored = state
            return true
        }
    }

    public func revokeAll() throws {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.validate()
            guard state.revocation < UInt64.max else { throw AccessError.corrupt }
            state.revocation += 1
            state.pendingEnrollment = nil
            stored = state
        }
    }

    func revoke(_ grant: AuthenticatedModeGrant) throws {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: issuer)
            guard state.revocation < UInt64.max else { throw AccessError.corrupt }
            state.revocation += 1
            state.pendingEnrollment = nil
            stored = state
        }
    }

    /// Replace active authority with a capability held only by an opaque,
    /// single-use management request. Existing extension grants are revoked too.
    func revokeAndReissueForPINChange(_ grant: AuthenticatedModeGrant) throws -> AuthenticatedModeGrant {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: issuer)
            guard state.revocation < UInt64.max else { throw AccessError.corrupt }
            state.revocation += 1
            state.pendingEnrollment = nil
            stored = state
            return self.grant(mode: grant.mode, state: state, purpose: .pinChange)
        }
    }

    func validatePINChangeGrant(_ grant: AuthenticatedModeGrant) throws {
        try file.withReadState { state in
            guard grant.purpose == .pinChange else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: issuer, permitsPINChange: true)
        }
    }

    public func cooldownRemaining() throws -> Int {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.validate()
            guard state.pendingOwnerPINChange == nil else { throw AccessError.unavailable }
            let now = try clock()
            try now.validate()
            let eligibleA = state.attemptsA.eligible(at: now)
            let eligibleB = state.attemptsB.eligible(at: now)
            stored = state
            // No role-specific budget/label is exposed on the neutral lock screen.
            guard !eligibleA, !eligibleB else { return 0 }
            let remaining = min(state.attemptsA.deadline!, state.attemptsB.deadline!) - now.uptime
            return Int(max(0, min(60, ceil(remaining))))
        }
    }

    func configuration(grant: AuthenticatedModeGrant) throws -> AccessConfiguration {
        try withValidatedGrant(grant) { $0 }
    }

    func withValidatedGrant<T>(_ grant: AuthenticatedModeGrant, _ body: (AccessConfiguration) throws -> T) throws -> T {
        try file.withReadState { state in
            try state.require(grant, issuer: issuer)
            return try body(state.configuration)
        }
    }

    @discardableResult public func setHidden(_ chat: ChatIdentity, hidden: Bool, grant: AuthenticatedModeGrant,
                          expectedRevision: UInt64) throws -> AuthenticatedModeGrant {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.authenticationRequired }
            try state.require(grant, issuer: self.issuer)
            guard grant.mode == .a else { throw AccessError.authenticationRequired }
            let config = state.configuration
            guard config.revision == expectedRevision else { throw AccessError.revisionConflict }
            guard config.revision < UInt64.max, chat.supported,
                  config.accounts.contains(where: { $0.identity == chat.account && $0.ownership == .shared }) else { throw AccessError.invalidConfiguration }
            var hiddenChats = config.hiddenChats
            var generations = config.hiddenChatGenerations
            if hidden {
                hiddenChats.insert(chat)
                if generations[chat] == nil { generations[chat] = UUID() }
            } else { hiddenChats.remove(chat); generations.removeValue(forKey: chat) }
            state.configuration = try AccessConfiguration(installation: config.installation, revision: config.revision + 1,
                accounts: config.accounts, hiddenChats: hiddenChats, hiddenChatGenerations: generations,
                selectedA: config.selectedA, selectedB: config.selectedB)
            state.pendingEnrollment = nil
            stored = state
            return self.grant(mode: grant.mode, state: state)
        }
    }

    func grant(mode: AccessMode, state: AccessVaultState, purpose: AccessGrantPurpose = .access) -> AuthenticatedModeGrant {
        let credential = mode == .a ? state.a : state.b
        return AuthenticatedModeGrant(mode: mode, issuer: issuer, configurationRevision: state.configuration.revision,
            credentialID: credential.id, credentialRevision: credential.revision, revocation: state.revocation, purpose: purpose)
    }

    static func validPIN(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48 ... 57).contains($0) }
    }
}
