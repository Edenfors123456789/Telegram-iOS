import XCTest
@testable import AccessModeCore

final class OwnerPINJournalTests: XCTestCase {
    private let prepared = Data("sealed-resource-rewrap-test-payload".utf8)

    func testVersionOneCannotContainJournalAndUnsupportedSchemaNeverFallsBackToSetup() throws {
        let f = try VaultFixture()
        XCTAssertEqual(try f.store.file.read().version, 1)
        let a = try f.store.authenticate(pin: "123456")
        _ = try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { self.prepared })
        XCTAssertEqual(try f.store.file.read().version, 2)
        try f.store.file.transaction { state, _ in state!.version = 1 }
        XCTAssertThrowsError(try f.store.isConfigured()) { XCTAssertEqual($0 as? AccessError, .corrupt) }
        XCTAssertThrowsError(try f.store.authenticate(pin: "123456"))
        try f.store.file.transaction { state, _ in state!.version = 4 }
        XCTAssertThrowsError(try f.store.isConfigured()) { XCTAssertEqual($0 as? AccessError, .unsupportedVersion) }
        XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321"))
    }

    func testPendingChangeDeniesBothRolesAndSurvivesRestartUntilResourcePublicationSucceeds() throws {
        let f = try VaultFixture()
        let a = try f.store.authenticate(pin: "123456")
        let b = try f.store.authenticate(pin: "654321")
        _ = try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { self.prepared })
        let restarted = try f.reopen()
        XCTAssertTrue(try restarted.isConfigured())
        XCTAssertTrue(try restarted.hasPendingOwnerPINChange())
        for pin in ["123456", "654321", "222222"] { XCTAssertThrowsError(try restarted.authenticate(pin: pin)) }
        XCTAssertThrowsError(try f.store.configuration(grant: a))
        XCTAssertThrowsError(try f.store.configuration(grant: b))
        XCTAssertThrowsError(try restarted.cooldownRemaining())
        var delivered = 0
        XCTAssertThrowsError(try restarted.resumeOwnerPINChange { payload in
            XCTAssertEqual(payload, self.prepared)
            delivered += 1
            throw AccessError.unavailable
        })
        XCTAssertEqual(delivered, 1)
        XCTAssertTrue(try restarted.hasPendingOwnerPINChange())
        XCTAssertTrue(try restarted.resumeOwnerPINChange { XCTAssertEqual($0, self.prepared); delivered += 1 })
        XCTAssertEqual(delivered, 2)
        XCTAssertFalse(try restarted.hasPendingOwnerPINChange())
        XCTAssertFalse(try restarted.resumeOwnerPINChange { _ in XCTFail("Completed work must not replay") })
        XCTAssertThrowsError(try f.store.configuration(grant: a))
        XCTAssertThrowsError(try restarted.authenticate(pin: "123456"))
        XCTAssertEqual(try restarted.authenticate(pin: "222222").mode, .a)
        XCTAssertEqual(try restarted.authenticate(pin: "654321").mode, .b)
    }

    func testOnlyCurrentAWithDistinctValidNewPINCanPrepareResources() throws {
        let f = try VaultFixture()
        let a = try f.store.authenticate(pin: "123456")
        let b = try f.store.authenticate(pin: "654321")
        var preparedCount = 0
        let prepare: () throws -> Data = { preparedCount += 1; return self.prepared }
        XCTAssertThrowsError(try f.store.beginOwnerPINChange(grant: b, currentPIN: "654321", newPIN: "222222", prepareProtectedResources: prepare))
        XCTAssertThrowsError(try f.store.beginOwnerPINChange(grant: a, currentPIN: "654321", newPIN: "222222", prepareProtectedResources: prepare))
        XCTAssertThrowsError(try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "654321", prepareProtectedResources: prepare))
        XCTAssertThrowsError(try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "bad", prepareProtectedResources: prepare))
        XCTAssertEqual(preparedCount, 0)
        XCTAssertThrowsError(try f.store.changePIN(grant: a, currentPIN: "123456", newPIN: "222222"))
        XCTAssertFalse(try f.store.hasPendingOwnerPINChange())
        XCTAssertEqual(try f.store.authenticate(pin: "123456").mode, .a)
    }

    func testRevocationWhilePendingCannotDeleteJournalOrRestoreOldAuthority() throws {
        let f = try VaultFixture()
        let a = try f.store.authenticate(pin: "123456")
        _ = try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { self.prepared })
        try f.store.revokeAll()
        let reopened = try f.reopen()
        XCTAssertTrue(try reopened.hasPendingOwnerPINChange())
        XCTAssertThrowsError(try f.store.setHidden(ChatIdentity(account: f.config.selectedA, peerNamespace: 0, peerID: 50), hidden: true, grant: a, expectedRevision: 1))
        XCTAssertThrowsError(try reopened.authenticate(pin: "654321"))
        XCTAssertTrue(try reopened.resumeOwnerPINChange { XCTAssertEqual($0, self.prepared) })
        XCTAssertEqual(try reopened.authenticate(pin: "222222").mode, .a)
    }

    func testPrepareOrCommitFailureLeavesOldCredentialsAndResourceStoreUntouched() throws {
        let f = try VaultFixture()
        let a = try f.store.authenticate(pin: "123456")
        XCTAssertThrowsError(try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { throw AccessError.unavailable }))
        XCTAssertFalse(try f.store.hasPendingOwnerPINChange())
        XCTAssertEqual(try f.store.authenticate(pin: "123456").mode, .a)
        XCTAssertEqual(try f.store.authenticate(pin: "654321").mode, .b)
        XCTAssertThrowsError(try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { Data() }))
        XCTAssertThrowsError(try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.directory.path)
            return self.prepared
        }))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.directory.path)
        XCTAssertFalse(try f.store.hasPendingOwnerPINChange())
        XCTAssertEqual(try f.store.authenticate(pin: "123456").mode, .a)
    }

    func testFinalFileFailureReplaysSamePlanAndNeverExposesHalfCommittedCredentials() throws {
        let f = try VaultFixture()
        let a = try f.store.authenticate(pin: "123456")
        _ = try f.store.beginOwnerPINChange(grant: a, currentPIN: "123456", newPIN: "222222", prepareProtectedResources: { self.prepared })
        var applied: Data?
        XCTAssertThrowsError(try f.store.resumeOwnerPINChange {
            applied = $0
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.directory.path)
        })
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.directory.path)
        XCTAssertEqual(applied, prepared)
        let restarted = try f.reopen()
        XCTAssertTrue(try restarted.hasPendingOwnerPINChange())
        XCTAssertThrowsError(try restarted.authenticate(pin: "222222"))
        XCTAssertTrue(try restarted.resumeOwnerPINChange { XCTAssertEqual($0, applied) })
        let state = try restarted.file.read()
        XCTAssertEqual(state.version, 2)
        XCTAssertEqual(try restarted.authenticate(pin: "222222").mode, .a)
        let bytes = try Data(contentsOf: f.file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("222222"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(String(decoding: prepared, as: UTF8.self)))
    }
}
