import XCTest
import Foundation
import LocalAuthentication
import AccessModeCore
@testable import PasscodeCore

private final class MigrationStorage: PasscodeStorage {
    var items: [String: Data] = [:]
    var deniedRemoval: String?
    func read(_ account: String, context: LAContext?) throws -> Data? { items[account] }
    func write(_ data: Data, account: String, biometric: Bool) throws { items[account] = data }
    func remove(_ account: String) throws {
        if account == deniedRemoval { throw PasscodeError.unavailable }
        items.removeValue(forKey: account)
    }
}

private final class MigrationDeviceKey: AccessDeviceKeyProvider {
    func loadKey(allowCreation: Bool) throws -> Data { Data(repeating: 0x49, count: 32) }
}

private final class MigrationFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dual-pin-owner-tests-\(UUID())")
    let storage = MigrationStorage()
    let legacy: PasscodeCredentialStore
    let vault: AccessCredentialStore
    let config: AccessConfiguration
    let environment = PasscodeEnvironment()

    init(mainApp: Bool = true) throws {
        legacy = PasscodeCredentialStore(storage: storage, iterations: { 600_000 })
        vault = try AccessCredentialStore(directory: directory, namespace: "test.owner-migration", keyProvider: MigrationDeviceKey(), iterations: 600_000)
        let installation = UUID()
        let account = AccountIdentity(installation: installation, environment: .production, recordID: 10, userID: 10)
        config = try AccessConfiguration(installation: installation, accounts: [AccountMembership(identity: account, ownership: .shared)], selectedA: account, selectedB: account)
        try environment.configure(PasscodeConfiguration(appGroupIdentifier: "group.org.negrfors.telegram.dualpin.owner-tests", processRole: mainApp ? .mainApp : .appExtension), privateAccessGroup: { "TESTTEAM01.org.negrfors.telegram.dualpin.owner-tests" })
        PasscodeSession.setApplicationAvailable(true)
    }

    var migration: DualPINLegacyMigration { DualPINLegacyMigration(legacy: legacy, environment: environment) }

    func install(owner: PasscodeSession?, publish: (PasscodeCredentialReference) throws -> Void = { _ in }) throws -> PasscodeCredentialReference {
        try migration.install(store: vault, configuration: config, pinA: "123456", pinB: "654321", ownerSession: owner, didCommitLegacyReference: publish)
    }

    func resourceKey(code: String) throws -> Data {
        let session = try legacy.verify(code, scope: .resource(namespace: "owner-test"))
        defer { session.invalidate() }
        return try session.withDerivedKey(namespace: "owner-test", domain: "migration-test") { $0 }
    }

    deinit {
        PasscodeSession.invalidateAll()
        PasscodeSession.setApplicationAvailable(false)
        try? FileManager.default.removeItem(at: directory)
    }
}

final class DualPINMigrationTests: XCTestCase {
    func testModeManagementRequirementRejectsLegacyOnlyChangesAndDestructiveReset() throws {
        let f = try MigrationFixture()
        let reference = try f.install(owner: nil)
        let resource = try f.resourceKey(code: "123456")
        let owner = try f.legacy.verify("123456", scope: .settings)
        defer { owner.invalidate() }
        f.legacy.requireModePINManagement()
        XCTAssertThrowsError(try f.legacy.setPasscode("222222", kind: .digits6, session: owner))
        XCTAssertThrowsError(try f.legacy.disablePasscode(session: owner))
        var cleaned = false
        XCTAssertThrowsError(try f.legacy.resetCredential(removingProtectedData: { cleaned = true }))
        XCTAssertFalse(cleaned)
        XCTAssertEqual(try f.legacy.managedReference()!, reference)
        XCTAssertEqual(try f.resourceKey(code: "123456"), resource)
        XCTAssertEqual(try f.vault.authenticate(pin: "123456").mode, .a)
        XCTAssertEqual(try f.vault.authenticate(pin: "654321").mode, .b)
    }

    func testInitialSetupAndExistingOwnerMigrationPreserveProtectedResourceKey() throws {
        let fresh = try MigrationFixture()
        let reference = try fresh.install(owner: nil)
        XCTAssertEqual(reference.kind, .digits6)
        XCTAssertEqual(try fresh.vault.authenticate(pin: "654321").mode, .b)
        let f = try MigrationFixture()
        _ = try f.legacy.setPasscode("1234", kind: .digits4, session: nil)
        let before = try f.resourceKey(code: "1234")
        let owner = try f.legacy.verify("1234", scope: .settings)
        var published: PasscodeCredentialReference?
        let result = try f.install(owner: owner, publish: { published = $0 })
        XCTAssertEqual(result, published)
        XCTAssertEqual(try f.resourceKey(code: "123456"), before)
        XCTAssertThrowsError(try f.legacy.verify("654321", scope: .resource(namespace: "owner-test")))
        XCTAssertEqual(try f.vault.authenticate(pin: "123456").mode, .a)
        XCTAssertEqual(try f.vault.authenticate(pin: "654321").mode, .b)
    }

    func testMissingRevokedOrWrongScopeOwnerCannotInitializeDualAccess() throws {
        let f = try MigrationFixture()
        _ = try f.legacy.setPasscode("1234", kind: .digits4, session: nil)
        XCTAssertThrowsError(try f.install(owner: nil))
        let resource = try f.legacy.verify("1234", scope: .resource(namespace: "owner-test"))
        XCTAssertThrowsError(try f.install(owner: resource))
        let owner = try f.legacy.verify("1234", scope: .settings)
        owner.invalidate()
        XCTAssertThrowsError(try f.install(owner: owner))
        XCTAssertFalse(try f.vault.isConfigured())
        XCTAssertEqual(try f.legacy.protectionSettings().passcode?.kind, .digits4)
    }

    func testExtensionOrExistingVaultCannotRewriteLegacyCredential() throws {
        let extensionFixture = try MigrationFixture(mainApp: false)
        XCTAssertThrowsError(try extensionFixture.install(owner: nil))
        XCTAssertNil(try extensionFixture.legacy.protectionSettings().passcode)
        let f = try MigrationFixture()
        _ = try f.install(owner: nil)
        let owner = try f.legacy.verify("123456", scope: .settings)
        let previous = f.storage.items["credential"]
        XCTAssertThrowsError(try f.migration.install(store: f.vault, configuration: f.config, pinA: "111111", pinB: "222222", ownerSession: owner, didCommitLegacyReference: { _ in XCTFail("Existing vault cannot rewrap legacy protection") }))
        XCTAssertEqual(f.storage.items["credential"], previous)
    }

    func testFailedAccessFileCommitStillPublishesKnownLegacyAAndPreservesResources() throws {
        let f = try MigrationFixture()
        _ = try f.legacy.setPasscode("1234", kind: .digits4, session: nil)
        let before = try f.resourceKey(code: "1234")
        let owner = try f.legacy.verify("1234", scope: .settings)
        var published: PasscodeCredentialReference?
        XCTAssertThrowsError(try f.install(owner: owner, publish: {
            published = $0
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.directory.path)
        }))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.directory.path)
        XCTAssertEqual(published?.kind, .digits6)
        XCTAssertFalse(try f.vault.isConfigured())
        XCTAssertEqual(try f.resourceKey(code: "123456"), before)
        XCTAssertThrowsError(try f.vault.authenticate(pin: "654321"))
    }

    func testBiometricCleanupFailureCannotPublishBAndCanResumeWithoutResourceLoss() throws {
        let f = try MigrationFixture()
        _ = try f.legacy.setPasscode("1234", kind: .digits4, session: nil)
        let before = try f.resourceKey(code: "1234")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(f.storage.items["credential"])) as? [String: Any])
        record["biometricAccount"] = "biometric.old"
        f.storage.items["credential"] = try JSONSerialization.data(withJSONObject: record)
        f.storage.items["biometric.old"] = Data(repeating: 0x51, count: 32)
        f.storage.deniedRemoval = "biometric.old"
        let owner = try f.legacy.verify("1234", scope: .settings)
        var reference: PasscodeCredentialReference?
        XCTAssertThrowsError(try f.install(owner: owner, publish: { reference = $0 }))
        XCTAssertNotNil(reference)
        XCTAssertFalse(try f.vault.isConfigured())
        XCTAssertFalse(try f.legacy.protectionSettings().biometricsEnabled)
        f.storage.deniedRemoval = nil
        try f.legacy.resumeCleanup()
        XCTAssertNil(f.storage.items["biometric.old"])
        XCTAssertEqual(try f.resourceKey(code: "123456"), before)
        let retry = try f.legacy.verify("123456", scope: .settings)
        _ = try f.install(owner: retry)
        XCTAssertEqual(try f.vault.authenticate(pin: "654321").mode, .b)
    }
}
