import XCTest
import Foundation
import AccessModeCore
@testable import AccessModeAccountBridge
@testable import TelegramCore
import SwiftSignalKit

final class AccountDirectoryCleanupTests: XCTestCase {
    private static let initializeLogger: Void = {
        let logger = Logger(rootPath: "", basePath: "")
        logger.logToFile = false; logger.logToConsole = false
        Logger.setSharedLogger(logger)
    }()
    private func fixture() throws -> BridgeFixture {
        _ = Self.initializeLogger
        let f = try BridgeFixture()
        // The red scaffold does not touch AccountManager. Still wait for its
        // initialization before any temporary-directory teardown can occur.
        _ = try value(f.manager.transaction { _ in true })
        return f
    }
    private func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let done = expectation(description: "directory result")
        var result: T?
        let disposable = signal.start(next: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 5); disposable.dispose()
        return try XCTUnwrap(result)
    }
    private func directory(_ f: BridgeFixture, record: Int64, root: URL? = nil) throws -> URL {
        let path = (root ?? f.directory).appendingPathComponent(accountRecordIdPathName(AccountRecordId(rawValue: record)))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: path.appendingPathComponent("marker"))
        return path
    }
    private func cleanup(_ f: BridgeFixture, record: Int64, gate: AccountDirectoryCleanupGate) -> Signal<Bool, NoError> {
        removeUnreferencedAccountDirectory(accountManager: f.manager, rootPath: f.directory.path,
            directoryName: accountRecordIdPathName(AccountRecordId(rawValue: record)), deletionGuard: { id, body in gate.perform(recordID: id.int64, body) })
    }

    func testBackgroundRetentionDoesNotPruneTemporaryRecordsOrStartLegacyLogout() throws {
        let f = try fixture(), temporary = AccountRecordId(rawValue: 81), loggedOut = AccountRecordId(rawValue: 82)
        let temporaryPath = try directory(f, record: temporary.int64)
        _ = try directory(f, record: 999)
        _ = try value(f.manager.transaction { transaction -> Bool in
            transaction.updateRecord(temporary, { _ in AccountRecord(id: temporary, attributes: [], temporarySessionId: f.manager.temporarySessionId ^ 1) })
            transaction.updateRecord(loggedOut, { _ in AccountRecord(id: loggedOut, attributes: [.loggedOut(LoggedOutAccountAttribute())], temporarySessionId: nil) })
            return true
        })
        let scanned = expectation(description: "background candidates reached fresh gate"), seen = Atomic<Bool>(value: false), jobs = Atomic<Int>(value: 0)
        let disposable = managedAccountCleanup(accountManager: f.manager, rootPath: f.directory.path,
            preserveSessionEvidence: true, directoryDeletionGuard: { id, _ in
                if id.int64 == 999, !seen.swap(true) { scanned.fulfill() }
                return false
            }, cleanup: { id, _ in
                _ = jobs.modify { $0 + 1 }
                return f.manager.transaction { transaction -> Void in transaction.updateRecord(id, { _ in nil }) }
            }).start()
        wait(for: [scanned], timeout: 5); disposable.dispose()
        let ids = try value(f.manager.transaction { $0.getRecords().map(\.id) })
        XCTAssertTrue(ids.contains(temporary)); XCTAssertTrue(ids.contains(loggedOut))
        XCTAssertEqual(jobs.with { $0 }, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryPath.path))
    }

    func testOrdinaryBackgroundCleanupStillPrunesAndStartsItsLegacyHandler() throws {
        let f = try fixture(), temporary = AccountRecordId(rawValue: 83), loggedOut = AccountRecordId(rawValue: 84)
        _ = try directory(f, record: 999)
        _ = try value(f.manager.transaction { transaction -> Bool in
            transaction.updateRecord(temporary, { _ in AccountRecord(id: temporary, attributes: [], temporarySessionId: f.manager.temporarySessionId ^ 1) })
            transaction.updateRecord(loggedOut, { _ in AccountRecord(id: loggedOut, attributes: [.loggedOut(LoggedOutAccountAttribute())], temporarySessionId: nil) })
            return true
        })
        let scanned = expectation(description: "legacy scan"), seen = Atomic<Bool>(value: false), jobs = Atomic<Int>(value: 0)
        let disposable = managedAccountCleanup(accountManager: f.manager, rootPath: f.directory.path,
            preserveSessionEvidence: false, directoryDeletionGuard: { id, _ in
                if id.int64 == 999, !seen.swap(true) { scanned.fulfill() }
                return false
            }, cleanup: { id, _ in
                _ = jobs.modify { $0 + 1 }
                return f.manager.transaction { transaction -> Void in transaction.updateRecord(id, { _ in nil }) }
            }).start()
        wait(for: [scanned], timeout: 5); disposable.dispose()
        let ids = try value(f.manager.transaction { $0.getRecords().map(\.id) })
        XCTAssertFalse(ids.contains(temporary)); XCTAssertFalse(ids.contains(loggedOut))
        XCTAssertEqual(jobs.with { $0 }, 1)
    }

    func testBackgroundDiscoveryUsesDurableOwnershipAndFreshDirectoryRemoval() throws {
        let f = try fixture(), gate = AccountDirectoryCleanupGate()
        gate.configure(AccessModeCoordinator(store: f.store))
        let shared = try directory(f, record: 10), orphan = try directory(f, record: 999)
        let scanned = expectation(description: "both background candidates handled"); scanned.expectedFulfillmentCount = 2
        let seen = Atomic<Set<Int64>>(value: [])
        let disposable = managedAccountCleanup(accountManager: f.manager, rootPath: f.directory.path,
            preserveSessionEvidence: true, directoryDeletionGuard: { id, body in
                let removed = gate.perform(recordID: id.int64, body)
                var first = false
                _ = seen.modify { values in var values = values; first = values.insert(id.int64).inserted; return values }
                if first { scanned.fulfill() }
                return removed
            }, cleanup: { _, _ in XCTFail("retention started legacy RPC"); return .complete() }).start()
        wait(for: [scanned], timeout: 5); disposable.dispose()
        _ = try value(f.manager.transaction { _ in true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testStartupDeniesUntilConfiguredAndThenOnlyAnUnownedDirectoryIsRemoved() throws {
        let f = try fixture(), gate = AccountDirectoryCleanupGate()
        let path = try directory(f, record: Int64.min)
        XCTAssertFalse(try value(cleanup(f, record: Int64.min, gate: gate)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let coordinator = AccessModeCoordinator(store: f.store)
        gate.configure(coordinator)
        XCTAssertTrue(try value(cleanup(f, record: Int64.min, gate: gate)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(coordinator.state, .locked)
    }

    func testConfiguredAndDetachedClaimedDirectoriesSurviveMissingNativeRecords() throws {
        let f = try fixture(), coordinator = AccessModeCoordinator(store: f.store), gate = AccountDirectoryCleanupGate()
        gate.configure(coordinator)
        let shared = try directory(f, record: f.config.selectedA.recordID)
        XCTAssertFalse(try value(cleanup(f, record: f.config.selectedA.recordID, gate: gate)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        let ticket = try coordinator.beginUnlock(pin: "123456"); try coordinator.completePreparation(ticket)
        let creation = try value(AccountEnrollmentBridge.createProvisionalAccount(accountManager: f.manager, coordinator: coordinator, ticket: ticket, environment: .production))
        guard case let .created(id, _) = creation else { XCTFail("creation refused"); return }
        let path = try directory(f, record: id.int64)
        let owner = try XCTUnwrap(coordinator.claimEnrollmentCleanup())
        _ = try value(AccountEnrollmentBridge.detachAuthForCleanup(accountManager: f.manager, coordinator: coordinator, cleanup: owner))
        XCTAssertFalse(try value(cleanup(f, record: id.int64, gate: gate)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try coordinator.claimEnrollmentCleanup()?.provisionalRecordID, id.int64)
    }

    func testFreshMetadataProtectsARecordPublishedAfterCleanupWasQueued() throws {
        let f = try fixture(), gate = AccountDirectoryCleanupGate(), id = AccountRecordId(rawValue: 42)
        gate.configure(AccessModeCoordinator(store: f.store))
        let path = try directory(f, record: id.int64)
        _ = try value(f.manager.transaction { _ in true })
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let published = expectation(description: "blocking transaction committed")
        let blocker = f.manager.transaction { transaction -> Bool in
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            transaction.updateRecord(id, { _ in AccountRecord(id: id, attributes: [], temporarySessionId: nil) })
            return true
        }.start(next: { _ in published.fulfill() })
        defer { release.signal(); blocker.dispose() }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let done = expectation(description: "fresh record retained")
        var result: Bool?
        let removal = cleanup(f, record: id.int64, gate: gate).start(next: { result = $0; done.fulfill() })
        release.signal()
        wait(for: [done, published], timeout: 5); removal.dispose()
        XCTAssertEqual(result, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testForeignRootSymlinkAndNoncanonicalNamesCannotDelete() throws {
        let f = try fixture()
        let foreign = f.directory.appendingPathComponent("foreign-root"), path = try directory(f, record: 75, root: foreign)
        let allow: AccountDirectoryDeletionGuard = { _, body in body() }
        XCTAssertFalse(try value(removeUnreferencedAccountDirectory(accountManager: f.manager, rootPath: foreign.path, directoryName: "account-75", deletionGuard: allow)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let link = f.directory.appendingPathComponent("account-76")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertFalse(try value(removeUnreferencedAccountDirectory(accountManager: f.manager, rootPath: f.directory.path, directoryName: link.lastPathComponent, deletionGuard: allow)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        for name in ["account-076", "account-+76", "account-../foreign-root/account-75", "../foreign-root/account-75", "account-18446744073709551616"] {
            XCTAssertFalse(try value(removeUnreferencedAccountDirectory(accountManager: f.manager, rootPath: f.directory.path, directoryName: name, deletionGuard: allow)))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("marker").path))
    }

    func testUnavailableAndShareOwnershipKeepTheDirectory() throws {
        let f = try fixture(), gate = AccountDirectoryCleanupGate(), path = try directory(f, record: 900)
        gate.configure(AccessModeCoordinator(store: f.store))
        f.keys.failOnLoad = f.keys.loads + 1
        XCTAssertFalse(try value(cleanup(f, record: 900, gate: gate)))
        f.keys.failOnLoad = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        gate.configure(AccessModeCoordinator(store: f.store, process: .shareExtension))
        XCTAssertFalse(try value(cleanup(f, record: 900, gate: gate)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
}
