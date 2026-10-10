import XCTest
@testable import AccessModeCore

final class AccountDirectoryRetentionTests: XCTestCase {
    private func ready(_ coordinator: AccessModeCoordinator, pin: String = "123456") throws -> AccessTicket {
        let ticket = try coordinator.beginUnlock(pin: pin)
        try coordinator.completePreparation(ticket)
        return ticket
    }

    func testEveryConfiguredRoleRetainsItsDirectoryWhileLockedAndAfterReopen() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        for (pin, record, user) in [("123456", Int64(20), Int64(200)), ("654321", Int64(21), Int64(201))] {
            let ticket = try ready(coordinator, pin: pin), permit = try coordinator.beginEnrollment(ticket: ticket)
            try coordinator.bindEnrollment(permit, provisionalRecordID: record, ticket: ticket)
            let account = AccountIdentity(installation: f.config.installation, environment: .production, recordID: record, userID: user)
            _ = try coordinator.completeEnrollment(permit, confirmedAccount: account, isPremium: false, ticket: ticket)
        }
        try coordinator.lock()
        let reopened = AccessModeCoordinator(store: try f.reopen()), before = try Data(contentsOf: f.file)
        for current in [coordinator, reopened] {
            for record in [f.config.selectedA.recordID, 20, 21] {
                var deleted = false
                let result = try current.withUnownedAccountDirectory(recordID: record) { deleted = true; return true }
                XCTAssertNil(result)
                XCTAssertFalse(deleted, "missing native metadata cannot override durable membership")
            }
            XCTAssertEqual(current.state, .locked)
        }
        XCTAssertEqual(try Data(contentsOf: f.file), before)
    }

    func testPendingEnrollmentAndClaimedCleanupRetainUntilExactAcknowledgment() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let ticket = try ready(coordinator), permit = try coordinator.beginEnrollment(ticket: ticket)
        try coordinator.bindEnrollment(permit, provisionalRecordID: -20, environment: .test, ticket: ticket)
        XCTAssertNil(try coordinator.withUnownedAccountDirectory(recordID: -20) { XCTFail("active provisional was deleted"); return true })
        XCTAssertEqual(try coordinator.withPolicy(ticket) { $0.mode }, .a)
        try coordinator.lock()
        let reopened = AccessModeCoordinator(store: try f.reopen())
        let owner = try XCTUnwrap(reopened.claimEnrollmentCleanup()), before = try Data(contentsOf: f.file)
        XCTAssertNil(try reopened.withUnownedAccountDirectory(recordID: -20) { XCTFail("claimed cleanup was deleted"); return true })
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        // No real native session in this fixture. Actual acknowledgment requires
        // the separately verified native server/local absence proof.
        try reopened.acknowledgeEnrollmentCleanup(owner)
        XCTAssertEqual(try reopened.withUnownedAccountDirectory(recordID: -20) { 71 }, 71)
        XCTAssertEqual(reopened.state, .locked)
    }

    func testUnownedSynchronousBodyWorksWithoutRewritingOrRevokingCurrentRole() throws {
        let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store)
        let ticket = try ready(coordinator, pin: "654321"), before = try Data(contentsOf: f.file)
        let directory = f.directory.appendingPathComponent("offline-unowned-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("marker"))
        XCTAssertEqual(try coordinator.withUnownedAccountDirectory(recordID: Int64.min) {
            try FileManager.default.removeItem(at: directory)
            return 19
        }, 19)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertThrowsError(try coordinator.withUnownedAccountDirectory(recordID: 900) { () -> Bool in throw AccessError.invalidTransition })
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        XCTAssertEqual(try coordinator.withPolicy(ticket) { $0.mode }, .b)
    }

    func testMissingCorruptUnavailableAndShareCannotRunAnyDeletion() throws {
        for variant in 0 ... 3 {
            let f = try VaultFixture(), coordinator = AccessModeCoordinator(store: f.store, process: variant == 3 ? .shareExtension : .mainApplication)
            switch variant {
            case 0: try FileManager.default.removeItem(at: f.file)
            case 1: try f.store.file.transaction { state, _ in state!.version = 99 }
            case 2: f.keys.denied = true
            default: break
            }
            var deleted = false
            XCTAssertThrowsError(try coordinator.withUnownedAccountDirectory(recordID: 900) { deleted = true; return true })
            XCTAssertFalse(deleted)
            f.keys.denied = false
        }
    }

    func testFreshEnrollmentCannotAcquireDirectoryDuringTheSynchronousDeletionBody() throws {
        let f = try VaultFixture(), deletion = AccessModeCoordinator(store: f.store), enrollment = AccessModeCoordinator(store: try f.reopen())
        let ticket = try ready(enrollment), permit = try enrollment.beginEnrollment(ticket: ticket)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), bindingStarted = DispatchSemaphore(value: 0), bound = DispatchSemaphore(value: 0)
        let finished = expectation(description: "synchronous deletion returned"), bindingFinished = expectation(description: "binding returned")
        DispatchQueue.global().async {
            do {
                _ = try deletion.withUnownedAccountDirectory(recordID: 20) {
                    entered.signal()
                    if release.wait(timeout: .now() + 3) != .success { throw AccessError.unavailable }
                    return true
                }
            } catch { XCTFail("deletion gate failed: \(error)") }
            finished.fulfill()
        }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async {
            bindingStarted.signal()
            do { try enrollment.bindEnrollment(permit, provisionalRecordID: 20, ticket: ticket) }
            catch { XCTFail("enrollment binding failed: \(error)") }
            bound.signal(); bindingFinished.fulfill()
        }
        XCTAssertEqual(bindingStarted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(bound.wait(timeout: .now() + 0.1), .timedOut, "durable read lock must cover actual deletion")
        release.signal()
        wait(for: [finished, bindingFinished], timeout: 5)
        XCTAssertNil(try deletion.withUnownedAccountDirectory(recordID: 20) { XCTFail("new owner was ignored"); return true })
    }
}
