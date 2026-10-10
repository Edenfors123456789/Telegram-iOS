import XCTest
@testable import AccessModeCore

final class TestDeviceKey: AccessDeviceKeyProvider {
    var key: Data? = Data(repeating: 0x57, count: 32)
    var denied = false
    var onLoad: (() throws -> Void)?
    var committedNamespaces: Set<String> = []
    var presenceDenied = false
    var presenceWriteDenied = false
    func hasCommittedState(namespace: String) throws -> Bool {
        if denied || presenceDenied { throw AccessError.unavailable }
        return committedNamespaces.contains(namespace)
    }
    func recordCommittedState(namespace: String) throws {
        if denied || presenceDenied || presenceWriteDenied { throw AccessError.unavailable }
        committedNamespaces.insert(namespace)
    }
    func loadKey(allowCreation: Bool) throws -> Data {
        if denied { throw AccessError.unavailable }
        guard let key else { throw AccessError.missingKey }
        try onLoad?()
        return key
    }
}

final class TestClock {
    var boot = "boot-1"
    var uptime: TimeInterval = 100
    func snapshot() -> AccessClockSnapshot { AccessClockSnapshot(bootID: boot, uptime: uptime) }
}

final class VaultFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dual-pin-tests-\(UUID())")
    let keys = TestDeviceKey()
    let clock = TestClock()
    let config: AccessConfiguration
    let store: AccessCredentialStore
    let file: URL

    init(initialize: Bool = true) throws {
        let installation = UUID()
        let identity = AccountIdentity(installation: installation, environment: .production, recordID: 10, userID: 10)
        self.config = try AccessConfiguration(installation: installation,
            accounts: [AccountMembership(identity: identity, ownership: .shared)], selectedA: identity, selectedB: identity)
        self.store = try AccessCredentialStore(directory: directory, namespace: "test.fork", keyProvider: keys,
            iterations: AccessCrypto.minimumIterations, clock: clock.snapshot)
        self.file = directory.appendingPathComponent("access-state.v1.enc")
        if initialize { try store.initialize(configuration: config, pinA: "123456", pinB: "654321") }
    }

    func reopen() throws -> AccessCredentialStore {
        try AccessCredentialStore(directory: directory, namespace: "test.fork", keyProvider: keys,
            iterations: AccessCrypto.minimumIterations, clock: clock.snapshot)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

final class CredentialTests: XCTestCase {
    func testDistinctSixDigitCodesIssueOnlyTheirOwnRole() throws {
        let f = try VaultFixture()
        XCTAssertEqual(try f.store.authenticate(pin: "123456").mode, .a)
        XCTAssertEqual(try f.store.authenticate(pin: "654321").mode, .b)
        for invalid in ["111111", "12345", "１２３４５６", "1234567", "abcdef"] {
            XCTAssertThrowsError(try f.store.authenticate(pin: invalid))
        }
        XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "111111", pinB: "222222"))
        let new = try VaultFixture(initialize: false)
        XCTAssertThrowsError(try new.store.initialize(configuration: new.config, pinA: "123456", pinB: "123456")) { error in
            XCTAssertEqual(error as? AccessError, .identicalPINs)
        }
    }

    func testSuccessfulBDoesNotResetOrConsumeABudgetAcrossRestart() throws {
        let f = try VaultFixture()
        for _ in 0 ..< 5 { XCTAssertThrowsError(try f.store.authenticate(pin: "111111")) }
        XCTAssertEqual(try f.store.authenticate(pin: "654321").mode, .b)
        let reopened = try f.reopen()
        XCTAssertThrowsError(try reopened.authenticate(pin: "111111"))
        XCTAssertThrowsError(try reopened.authenticate(pin: "123456"))
        XCTAssertEqual(try reopened.authenticate(pin: "654321").mode, .b)
        f.clock.uptime += 61
        XCTAssertEqual(try reopened.authenticate(pin: "123456").mode, .a)
    }

    func testRebootDoesNotBypassPersistentCooldown() throws {
        let f = try VaultFixture()
        for _ in 0 ..< 6 { XCTAssertThrowsError(try f.store.authenticate(pin: "111111")) }
        f.clock.boot = "boot-2"
        f.clock.uptime = 2
        let reopened = try f.reopen()
        XCTAssertThrowsError(try reopened.authenticate(pin: "123456")) { XCTAssertEqual($0 as? AccessError, .cooldown) }
        f.clock.uptime = 61
        XCTAssertThrowsError(try reopened.authenticate(pin: "654321"))
        f.clock.uptime = 63
        XCTAssertEqual(try reopened.authenticate(pin: "654321").mode, .b)
    }

    func testPINChangeRequiresOwnCodeRejectsEqualityAndRevokesOldGrants() throws {
        let f = try VaultFixture()
        let b = try f.store.authenticate(pin: "654321")
        XCTAssertThrowsError(try f.store.changePIN(grant: b, currentPIN: "123456", newPIN: "222222"))
        XCTAssertThrowsError(try f.store.changePIN(grant: b, currentPIN: "654321", newPIN: "123456")) { XCTAssertEqual($0 as? AccessError, .identicalPINs) }
        try f.store.changePIN(grant: b, currentPIN: "654321", newPIN: "222222")
        XCTAssertThrowsError(try f.store.configuration(grant: b))
        XCTAssertThrowsError(try f.store.authenticate(pin: "654321"))
        XCTAssertEqual(try f.store.authenticate(pin: "222222").mode, .b)
        XCTAssertEqual(try f.store.authenticate(pin: "123456").mode, .a)
    }

    func testMissingKeyAndCorruptionNeverReinitializeExistingVault() throws {
        let f = try VaultFixture()
        let bytes = try Data(contentsOf: f.file)
        f.keys.key = nil
        XCTAssertThrowsError(try f.store.authenticate(pin: "123456")) { XCTAssertEqual($0 as? AccessError, .missingKey) }
        XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "111111", pinB: "222222"))
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
        f.keys.key = Data(repeating: 0x57, count: 32)
        var envelope = try JSONDecoder().decode(EncryptedAccessFile<AccessVaultState>.Envelope.self, from: bytes)
        var ciphertext = envelope.ciphertext
        ciphertext[20] ^= 1
        envelope = .init(version: envelope.version, revision: envelope.revision, ciphertext: ciphertext)
        try JSONEncoder().encode(envelope).write(to: f.file)
        XCTAssertThrowsError(try f.store.authenticate(pin: "123456")) { XCTAssertEqual($0 as? AccessError, .corrupt) }
        XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "111111", pinB: "222222"))
    }

    func testEncryptedFileHasNoPlaintextPINAndIsBoundToNamespaceAndRevision() throws {
        let f = try VaultFixture()
        let bytes = try Data(contentsOf: f.file)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("123456"))
        XCTAssertFalse(text.contains("654321"))
        XCTAssertFalse(text.contains(f.config.installation.uuidString))
        let different = try AccessCredentialStore(directory: f.directory, namespace: "other.fork", keyProvider: f.keys, iterations: 600_000)
        XCTAssertThrowsError(try different.authenticate(pin: "123456"))
        let envelope = try JSONDecoder().decode(EncryptedAccessFile<AccessVaultState>.Envelope.self, from: bytes)
        let modified = EncryptedAccessFile<AccessVaultState>.Envelope(version: 1, revision: envelope.revision + 1, ciphertext: envelope.ciphertext)
        try JSONEncoder().encode(modified).write(to: f.file)
        XCTAssertThrowsError(try f.store.authenticate(pin: "123456"))
    }

    func testIssuerAndConfigurationRevisionBindGrantsAndBDeniesManagement() throws {
        let f = try VaultFixture()
        let a = try f.store.authenticate(pin: "123456")
        let b = try f.store.authenticate(pin: "654321")
        let otherInstance = try f.reopen()
        XCTAssertThrowsError(try otherInstance.configuration(grant: a))
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 50)
        XCTAssertThrowsError(try f.store.setHidden(chat, hidden: true, grant: b, expectedRevision: 1))
        XCTAssertThrowsError(try f.store.setHidden(chat, hidden: true, grant: a, expectedRevision: 99)) { XCTAssertEqual($0 as? AccessError, .revisionConflict) }
        try f.store.setHidden(chat, hidden: true, grant: a, expectedRevision: 1)
        XCTAssertThrowsError(try f.store.configuration(grant: a))
        let reopenedA = try otherInstance.authenticate(pin: "123456")
        XCTAssertTrue(try otherInstance.configuration(grant: reopenedA).hiddenChats.contains(chat))
    }

    func testStorageFailureCannotReturnAnAuthenticationGrant() throws {
        let f = try VaultFixture()
        f.keys.denied = true
        XCTAssertThrowsError(try f.store.authenticate(pin: "123456"))
        f.keys.denied = false
        let bytes = try Data(contentsOf: f.file)
        // Remove directory write permission after a successful read/key load, so the
        // authentication result exists but committing it cannot create the temporary file.
        let directoryPath = f.directory.path
        f.keys.onLoad = { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directoryPath) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.directory.path) }
        XCTAssertThrowsError(try f.store.authenticate(pin: "123456")) { XCTAssertEqual($0 as? AccessError, .unavailable) }
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
    }

    func testSwappedCredentialsOrUntrustedWorkFactorFailBeforeDerivation() throws {
        let f = try VaultFixture()
        let raw = try EncryptedAccessFile<AccessVaultState>(directory: f.directory, namespace: "test.fork", keyProvider: f.keys)
        try raw.transaction { state, _ in
            let old = state!
            state = AccessVaultState(version: 1, configuration: old.configuration, a: old.b, b: old.a,
                attemptsA: old.attemptsA, attemptsB: old.attemptsB, revocation: old.revocation)
        }
        XCTAssertThrowsError(try f.store.authenticate(pin: "123456")) { XCTAssertEqual($0 as? AccessError, .corrupt) }
        try raw.transaction { state, _ in
            let originalA = state!.b
            state!.b = state!.a
            state!.a = PINCredential(mode: .a, id: originalA.id, revision: 1, salt: originalA.salt, iterations: Int.max, proof: originalA.proof)
        }
        XCTAssertThrowsError(try f.store.authenticate(pin: "654321")) { XCTAssertEqual($0 as? AccessError, .corrupt) }
    }
}

final class CoordinatorTests: XCTestCase {
    func testPreparingCannotSubmitAndOldTicketsCannotSurviveModeTransition() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let a = try coordinator.beginUnlock(pin: "123456")
        XCTAssertEqual(coordinator.state, .preparing(.a))
        XCTAssertThrowsError(try coordinator.withPolicy(a) { $0.visibleAccounts })
        XCTAssertEqual(try coordinator.withPolicy(a, requireReady: false) { $0.mode }, .a)
        try coordinator.completePreparation(a)
        XCTAssertEqual(coordinator.state, .active(.a))
        let b = try coordinator.beginUnlock(pin: "654321")
        XCTAssertThrowsError(try coordinator.withPolicy(a) { $0.visibleAccounts })
        // Discarding an old result must not disrupt the new generation's preparation.
        XCTAssertEqual(coordinator.state, .preparing(.b))
        XCTAssertThrowsError(try coordinator.completePreparation(a))
        XCTAssertEqual(coordinator.state, .preparing(.b))
        try coordinator.completePreparation(b)
        XCTAssertEqual(try coordinator.withPolicy(b) { $0.mode }, .b)
    }

    func testLocalLockSurvivesIOFailureAndPersistentRevocationReachesOtherProcess() throws {
        let f = try VaultFixture()
        let extensionStore = try f.reopen()
        let extensionCoordinator = AccessModeCoordinator(store: extensionStore, process: .shareExtension)
        let ticket = try extensionCoordinator.beginUnlock(pin: "654321")
        try extensionCoordinator.completePreparation(ticket)
        try f.store.revokeAll()
        XCTAssertThrowsError(try extensionCoordinator.withPolicy(ticket) { $0.visibleAccounts })
        XCTAssertEqual(extensionCoordinator.state, .locked)
        let main = AccessModeCoordinator(store: f.store)
        let mainTicket = try main.beginUnlock(pin: "123456")
        try main.completePreparation(mainTicket)
        f.keys.denied = true
        XCTAssertThrowsError(try main.lock())
        XCTAssertEqual(main.state, .locked)
        XCTAssertThrowsError(try main.withPolicy(mainTicket) { $0.visibleAccounts })
    }
}
