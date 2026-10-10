import XCTest
import Foundation
import LocalAuthentication
import AccessModeCore
import TelegramCore
import SwiftSignalKit
@testable import PasscodeCore

private final class MigrationStorage: PasscodeStorage {
    var items: [String: Data] = [:]
    var deniedRemoval: String?
    var deniedWrite: String?
    func read(_ account: String, context: LAContext?) throws -> Data? { items[account] }
    func write(_ data: Data, account: String, biometric: Bool) throws {
        if account == deniedWrite { throw PasscodeError.unavailable }
        items[account] = data
    }
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
    var journal: DualPINLegacyJournal { DualPINLegacyJournal(legacy: legacy, environment: environment) }

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

final class DualPINJournalTests: XCTestCase {
    func testLegacyWriteFailureCannotFinalizeJournalAndCanRetryWithoutResourceLoss() throws {
        let f = try MigrationFixture()
        _ = try f.install(owner: nil)
        let key = try f.resourceKey(code: "123456")
        let original = f.storage.items["credential"]
        let a = try f.vault.authenticate(pin: "123456")
        _ = try f.journal.stage(store: f.vault, grant: a, currentPIN: "123456", newPIN: "222222")
        f.storage.deniedWrite = "credential"
        XCTAssertThrowsError(try f.journal.recover(store: f.vault, didCommitLegacyReference: { _ in XCTFail("No legacy commit") }))
        XCTAssertEqual(f.storage.items["credential"], original)
        XCTAssertTrue(try f.vault.hasPendingOwnerPINChange())
        XCTAssertThrowsError(try f.vault.authenticate(pin: "654321"))
        f.storage.deniedWrite = nil
        XCTAssertTrue(try f.journal.recover(store: f.vault, didCommitLegacyReference: { _ in }))
        XCTAssertEqual(try f.resourceKey(code: "222222"), key)
    }

    func testFinalVaultWriteFailureAfterLegacyCommitReplaysWithoutRewrappingAgain() throws {
        let f = try MigrationFixture()
        _ = try f.install(owner: nil)
        let key = try f.resourceKey(code: "123456")
        let a = try f.vault.authenticate(pin: "123456")
        _ = try f.journal.stage(store: f.vault, grant: a, currentPIN: "123456", newPIN: "222222")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.directory.path) }
        XCTAssertThrowsError(try f.journal.recover(store: f.vault, didCommitLegacyReference: { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.directory.path)
        }))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.directory.path)
        let appliedRecord = f.storage.items["credential"]
        XCTAssertTrue(try f.vault.hasPendingOwnerPINChange())
        XCTAssertThrowsError(try f.vault.authenticate(pin: "222222"))
        XCTAssertEqual(try f.resourceKey(code: "222222"), key)
        XCTAssertTrue(try f.journal.recover(store: f.vault, didCommitLegacyReference: { _ in }))
        XCTAssertEqual(f.storage.items["credential"], appliedRecord)
        XCTAssertEqual(try f.resourceKey(code: "222222"), key)
        XCTAssertEqual(try f.vault.authenticate(pin: "222222").mode, .a)
    }

    func testBiometricCleanupFailureKeepsJournalDeniedUntilExactCleanupCompletes() throws {
        let f = try MigrationFixture()
        _ = try f.install(owner: nil)
        let key = try f.resourceKey(code: "123456")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(f.storage.items["credential"])) as? [String: Any])
        record["biometricAccount"] = "biometric.journal-old"
        f.storage.items["credential"] = try JSONSerialization.data(withJSONObject: record)
        f.storage.items["biometric.journal-old"] = Data(repeating: 0x39, count: 32)
        let a = try f.vault.authenticate(pin: "123456")
        _ = try f.journal.stage(store: f.vault, grant: a, currentPIN: "123456", newPIN: "222222")
        f.storage.deniedRemoval = "biometric.journal-old"
        XCTAssertThrowsError(try f.journal.recover(store: f.vault, didCommitLegacyReference: { _ in XCTFail("Incomplete cleanup") }))
        XCTAssertTrue(try f.vault.hasPendingOwnerPINChange())
        XCTAssertFalse(try f.legacy.protectionSettings().biometricsEnabled)
        XCTAssertThrowsError(try f.vault.authenticate(pin: "222222"))
        f.storage.deniedRemoval = nil
        XCTAssertTrue(try f.journal.recover(store: f.vault, didCommitLegacyReference: { _ in }))
        XCTAssertNil(f.storage.items["biometric.journal-old"])
        XCTAssertEqual(try f.resourceKey(code: "222222"), key)
    }

    func testAuthenticatedPlanRejectsTamperingWrongGroupAndUnexpectedLegacyRecord() throws {
        let f = try MigrationFixture()
        _ = try f.install(owner: nil)
        let owner = try f.legacy.verify("123456", scope: .settings)
        let context = try f.environment.sharedAccessGroup()
        let plan = try f.legacy.prepareOwnerPINRewrap("222222", session: owner, context: context)
        owner.invalidate()
        f.legacy.requireModePINManagement()
        let original = f.storage.items["credential"]
        var tampered = plan
        tampered[20] ^= 1
        XCTAssertThrowsError(try f.legacy.applyOwnerPINRewrap(tampered, context: context))
        XCTAssertThrowsError(try f.legacy.applyOwnerPINRewrap(plan, context: "group.other.test"))
        XCTAssertEqual(f.storage.items["credential"], original)
        var record = try JSONDecoder().decode(PasscodeCredentialStore.Record.self, from: try XCTUnwrap(original))
        record.id = UUID().uuidString
        f.storage.items["credential"] = try JSONEncoder().encode(record)
        let otherRecord = f.storage.items["credential"]
        XCTAssertThrowsError(try f.legacy.applyOwnerPINRewrap(plan, context: context))
        XCTAssertEqual(f.storage.items["credential"], otherRecord)
        f.storage.items.removeValue(forKey: "credential")
        XCTAssertThrowsError(try f.legacy.applyOwnerPINRewrap(plan, context: context))
        XCTAssertNil(f.storage.items["credential"])
    }
    func testStagingDoesNotChangeResourcesAndRestartRecoveryPreservesTheirKey() throws {
        let f = try MigrationFixture()
        _ = try f.install(owner: nil)
        let key = try f.resourceKey(code: "123456")
        let original = f.storage.items["credential"]
        let a = try f.vault.authenticate(pin: "123456")
        _ = try f.journal.stage(store: f.vault, grant: a, currentPIN: "123456", newPIN: "222222")
        XCTAssertEqual(f.storage.items["credential"], original)
        XCTAssertTrue(try f.vault.hasPendingOwnerPINChange())
        XCTAssertThrowsError(try f.vault.authenticate(pin: "123456"))
        XCTAssertThrowsError(try f.vault.authenticate(pin: "654321"))
        let restarted = PasscodeCredentialStore(storage: f.storage, iterations: { 600_000 })
        let adapter = DualPINLegacyJournal(legacy: restarted, environment: f.environment)
        var published: PasscodeCredentialReference?
        XCTAssertTrue(try adapter.recover(store: f.vault, didCommitLegacyReference: { published = $0 }))
        XCTAssertEqual(published?.kind, .digits6)
        XCTAssertEqual(try f.resourceKey(code: "222222"), key)
        XCTAssertThrowsError(try f.resourceKey(code: "123456"))
        XCTAssertEqual(try f.vault.authenticate(pin: "222222").mode, .a)
        XCTAssertEqual(try f.vault.authenticate(pin: "654321").mode, .b)
        XCTAssertFalse(try adapter.recover(store: f.vault, didCommitLegacyReference: { _ in XCTFail("Already completed journal") }))
    }

    func testReferencePublicationFailureLeavesDeniedJournalAndRetriesSameWrapping() throws {
        let f = try MigrationFixture()
        _ = try f.install(owner: nil)
        let key = try f.resourceKey(code: "123456")
        let a = try f.vault.authenticate(pin: "123456")
        _ = try f.journal.stage(store: f.vault, grant: a, currentPIN: "123456", newPIN: "222222")
        var publications = 0
        XCTAssertThrowsError(try f.journal.recover(store: f.vault, didCommitLegacyReference: { _ in
            publications += 1
            throw PasscodeError.unavailable
        }))
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(try f.vault.hasPendingOwnerPINChange())
        XCTAssertThrowsError(try f.vault.authenticate(pin: "222222"))
        XCTAssertEqual(try f.resourceKey(code: "222222"), key)
        let appliedRecord = f.storage.items["credential"]
        let restarted = PasscodeCredentialStore(storage: f.storage, iterations: { 600_000 })
        let adapter = DualPINLegacyJournal(legacy: restarted, environment: f.environment)
        XCTAssertTrue(try adapter.recover(store: f.vault, didCommitLegacyReference: { reference in
            publications += 1
            XCTAssertEqual(try restarted.managedReference()!, reference)
        }))
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(f.storage.items["credential"], appliedRecord)
        XCTAssertEqual(try f.resourceKey(code: "222222"), key)
        XCTAssertEqual(try f.vault.authenticate(pin: "222222").mode, .a)
    }

    func testBAndExtensionCannotStageOrReplayOwnerChanges() throws {
        let f = try MigrationFixture()
        _ = try f.install(owner: nil)
        let original = f.storage.items["credential"]
        let b = try f.vault.authenticate(pin: "654321")
        XCTAssertThrowsError(try f.journal.stage(store: f.vault, grant: b, currentPIN: "654321", newPIN: "222222"))
        XCTAssertEqual(f.storage.items["credential"], original)
        let extensionEnvironment = PasscodeEnvironment()
        try extensionEnvironment.configure(PasscodeConfiguration(appGroupIdentifier: "group.org.negrfors.telegram.dualpin.owner-tests", processRole: .appExtension))
        let adapter = DualPINLegacyJournal(legacy: f.legacy, environment: extensionEnvironment)
        let a = try f.vault.authenticate(pin: "123456")
        XCTAssertThrowsError(try adapter.stage(store: f.vault, grant: a, currentPIN: "123456", newPIN: "222222"))
        XCTAssertThrowsError(try adapter.recover(store: f.vault, didCommitLegacyReference: { _ in XCTFail("Extension publication") }))
        XCTAssertFalse(try f.vault.hasPendingOwnerPINChange())
    }
}

final class DualPINReferenceCommitTests: XCTestCase {
    private func manager(_ f: MigrationFixture, reference: Atomic<PasscodeCredentialReference?>) -> AccountManager<TelegramAccountManagerTypes> {
        // Upstream initializes a missing atomic state only through this flag.
        // Use it solely for our verified-new UUID fixture, never for the reader.
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("account-manager").path))
        let manager = AccountManager<TelegramAccountManagerTypes>(basePath: f.directory.appendingPathComponent("account-manager").path,
            isTemporary: false, isReadOnly: false, useCaches: false, removeDatabaseOnError: true,
            accessChallenge: AccountManagerAccessChallenge(prepare: { _ in _ = f.directory }, resolve: { _, _ in
                if let value = reference.with({ $0 }) { return accessChallengeData(reference: value) }
                return .some(.none)
            }, finishInitialization: {}))
        let ready = expectation(description: "Isolated metadata initialized")
        let disposable = manager.transaction { $0.getAccessChallengeData() }.start(next: { data in
            XCTAssertEqual(data, .none)
            ready.fulfill()
        })
        wait(for: [ready], timeout: 5)
        disposable.dispose()
        return manager
    }

    func testInitialSetupAcknowledgesRealMetadataAndPreservesOwnerResourcesBeforeFreshPIN() throws {
        let f = try MigrationFixture()
        _ = try f.legacy.setPasscode("1234", kind: .digits4, session: nil)
        let before = try f.resourceKey(code: "1234")
        let owner = try f.legacy.verify("1234", scope: .settings)
        defer { owner.invalidate() }
        let trusted = Atomic<PasscodeCredentialReference?>(value: nil)
        let manager = self.manager(f, reference: trusted)
        let coordinator = AccessInitialSetupCoordinator(store: f.vault)
        let request = try coordinator.prepare()
        let done = expectation(description: "Initial owner/resource/reference commit")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try coordinator.execute(request) {
                    try f.migration.installForSetup(store: f.vault, configuration: f.config,
                        pinA: "123456", pinB: "654321", ownerSession: owner, didCommitLegacyReference: { reference in
                            _ = trusted.swap(reference)
                            try commitDualPINLegacyReference(reference, accountManager: manager)
                        })
                }
            } catch { XCTFail("Initial setup failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(coordinator.state, .finished)
        XCTAssertEqual(try f.resourceKey(code: "123456"), before)
        XCTAssertThrowsError(try f.legacy.verify("654321", scope: .resource(namespace: "owner-test")))
        XCTAssertEqual(try f.vault.authenticate(pin: "123456").mode, .a)
        XCTAssertEqual(try f.vault.authenticate(pin: "654321").mode, .b)
        let reference = try XCTUnwrap(try f.legacy.managedReference() ?? nil)
        let read = expectation(description: "Initial six-digit reference acknowledged")
        let disposable = manager.transaction { $0.getAccessChallengeData() }.start(next: { data in
            XCTAssertEqual(data, accessChallengeData(reference: reference))
            read.fulfill()
        })
        wait(for: [read], timeout: 5)
        disposable.dispose()
    }

    func testMainCallerAndSilentlyRejectedReferenceAreDenied() throws {
        let f = try MigrationFixture()
        let reference = PasscodeCredentialReference(id: UUID().uuidString, kind: .digits6)
        let manager = self.manager(f, reference: Atomic(value: nil))
        XCTAssertThrowsError(try commitDualPINLegacyReference(reference, accountManager: manager))
        let done = expectation(description: "Rejected publication")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try commitDualPINLegacyReference(reference, accountManager: manager)
                XCTFail("Silently refused metadata cannot acknowledge publication")
            } catch {}
            done.fulfill()
        }
        wait(for: [done], timeout: 7)
    }

    func testAcknowledgedReferenceSurvivesReopeningRealMetadataWithNoResolverFallback() throws {
        let f = try MigrationFixture()
        let trusted = Atomic<PasscodeCredentialReference?>(value: nil)
        let manager = self.manager(f, reference: trusted)
        let reference = PasscodeCredentialReference(id: UUID().uuidString, kind: .digits6)
        _ = trusted.swap(reference)
        let done = expectation(description: "Committed reference")
        DispatchQueue.global(qos: .userInitiated).async {
            do { try commitDualPINLegacyReference(reference, accountManager: manager) }
            catch { XCTFail("Publication failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 7)
        let reader = AccountManager<TelegramAccountManagerTypes>(basePath: manager.basePath,
            isTemporary: false, isReadOnly: true, useCaches: false, removeDatabaseOnError: false,
            accessChallenge: AccountManagerAccessChallenge(prepare: { _ in }, resolve: { _, _ in nil }, finishInitialization: {}))
        let read = expectation(description: "Read committed reference")
        let disposable = reader.transaction { $0.getAccessChallengeData() }.start(next: { data in
            XCTAssertEqual(data, accessChallengeData(reference: reference))
            read.fulfill()
        })
        wait(for: [read], timeout: 5)
        disposable.dispose()
    }

    func testTimedOutPublicationKeepsRealJournalDeniedAndLateCommitCanRetry() throws {
        let f = try MigrationFixture()
        _ = try f.install(owner: nil)
        let key = try f.resourceKey(code: "123456")
        let trusted = Atomic<PasscodeCredentialReference?>(value: nil)
        let manager = self.manager(f, reference: trusted)
        let a = try f.vault.authenticate(pin: "123456")
        _ = try f.journal.stage(store: f.vault, grant: a, currentPIN: "123456", newPIN: "222222")
        let blocker = DispatchSemaphore(value: 0)
        let blocking = expectation(description: "Only isolated metadata queue blocked")
        let blocked = manager.transaction { _ -> Void in
            blocking.fulfill()
            _ = blocker.wait(timeout: .now() + 5)
        }.start()
        defer { blocker.signal(); blocked.dispose() }
        wait(for: [blocking], timeout: 5)
        let failed = expectation(description: "Publication timed out")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try f.journal.recover(store: f.vault, didCommitLegacyReference: { reference in
                    _ = trusted.swap(reference)
                    try commitDualPINLegacyReference(reference, accountManager: manager, timeout: 0.05)
                })
                XCTFail("Timed-out reference publication cannot finalize the journal")
            } catch {}
            failed.fulfill()
        }
        wait(for: [failed], timeout: 3)
        XCTAssertTrue(try f.vault.hasPendingOwnerPINChange())
        XCTAssertThrowsError(try f.vault.authenticate(pin: "222222"))
        let applied = f.storage.items["credential"]
        blocker.signal()
        let retry = expectation(description: "Late metadata publication replayed")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let recovered = try f.journal.recover(store: f.vault, didCommitLegacyReference: { reference in
                    try commitDualPINLegacyReference(reference, accountManager: manager)
                })
                XCTAssertTrue(recovered)
            } catch { XCTFail("Retry failed: \(error)") }
            retry.fulfill()
        }
        wait(for: [retry], timeout: 7)
        XCTAssertEqual(f.storage.items["credential"], applied)
        XCTAssertEqual(try f.resourceKey(code: "222222"), key)
        XCTAssertEqual(try f.vault.authenticate(pin: "222222").mode, .a)
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
