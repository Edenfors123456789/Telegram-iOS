import XCTest
@testable import AccessModeCore

final class InitialSetupReceiptTests: XCTestCase {
    func testCompletionRevokesInitialAuthorityAndRequiresFreshPINWithoutReturningAGrant() throws {
        let f = try VaultFixture(initialize: false)
        let receipt = try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321")
        let initial = try f.store.authenticate(pin: "123456")
        try f.store.finishInitialSetup(receipt)
        XCTAssertThrowsError(try f.store.configuration(grant: initial))
        let fresh = try f.store.authenticate(pin: "654321")
        XCTAssertEqual(try f.store.configuration(grant: fresh), f.config)
        XCTAssertThrowsError(try f.store.finishInitialSetup(receipt))
        XCTAssertEqual(try f.store.configuration(grant: fresh), f.config)
    }

    func testForeignOrReopenedStoreCannotUseReceiptToRevokeCurrentAuthority() throws {
        let f = try VaultFixture(initialize: false)
        let receipt = try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321")
        let other = try VaultFixture()
        let foreign = try other.store.authenticate(pin: "123456")
        XCTAssertThrowsError(try other.store.finishInitialSetup(receipt))
        XCTAssertEqual(try other.store.configuration(grant: foreign), other.config)
        let reopened = try f.reopen()
        let fresh = try reopened.authenticate(pin: "123456")
        XCTAssertThrowsError(try reopened.finishInitialSetup(receipt))
        XCTAssertEqual(try reopened.configuration(grant: fresh), f.config)
    }

    func testConfigurationMutationOrLockMakesReceiptStaleWithoutDisturbingNewAuthority() throws {
        let f = try VaultFixture(initialize: false)
        let receipt = try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321")
        let a = try f.store.authenticate(pin: "123456")
        let chat = ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 50)
        _ = try f.store.setHidden(chat, hidden: true, grant: a, expectedRevision: 1)
        let fresh = try f.store.authenticate(pin: "123456")
        XCTAssertThrowsError(try f.store.finishInitialSetup(receipt))
        XCTAssertTrue(try f.store.configuration(grant: fresh).hiddenChats.contains(chat))
        let locked = try VaultFixture(initialize: false)
        let old = try locked.store.initialize(configuration: locked.config, pinA: "123456", pinB: "654321")
        try locked.store.revokeAll()
        let b = try locked.store.authenticate(pin: "654321")
        XCTAssertThrowsError(try locked.store.finishInitialSetup(old))
        XCTAssertEqual(try locked.store.configuration(grant: b), locked.config)
    }

    func testReceiptCannotRecreateAbsentVaultOrIgnoreUnavailableKey() throws {
        let f = try VaultFixture(initialize: false)
        let receipt = try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321")
        f.keys.denied = true
        XCTAssertThrowsError(try f.store.finishInitialSetup(receipt))
        f.keys.denied = false
        // Remove only this test fixture's own file; completion must never create it.
        try FileManager.default.removeItem(at: f.file)
        XCTAssertThrowsError(try f.store.finishInitialSetup(receipt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
    }

    func testInitialWriteFailureReturnsNoReceiptAndCanRetryKnownOwnerPreparation() throws {
        let f = try VaultFixture(initialize: false)
        var receipt: AccessInitialSetupReceipt?
        var prepared = false
        XCTAssertThrowsError(receipt = try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321", prepareProtectedResources: {
            prepared = true
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.directory.path)
        }))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.directory.path)
        XCTAssertTrue(prepared); XCTAssertNil(receipt); XCTAssertFalse(try f.store.isConfigured())
        let retry = try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321")
        try f.store.finishInitialSetup(retry)
        XCTAssertEqual(try f.store.authenticate(pin: "654321").mode, .b)
    }
}
