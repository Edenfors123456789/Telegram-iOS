import XCTest
@testable import AccessModeCore

final class StorageTests: XCTestCase {
    struct Counter: Codable { var value: Int }

    func testTwoWritersSerializeAndStaleRevisionCannotOverwrite() throws {
        let f = try VaultFixture(initialize: false)
        let first = try EncryptedAccessFile<Counter>(directory: f.directory, namespace: "counter", keyProvider: f.keys)
        let second = try EncryptedAccessFile<Counter>(directory: f.directory, namespace: "counter", keyProvider: f.keys)
        try first.transaction(allowInitialization: true) { state, _ in state = Counter(value: 0) }
        let failureLock = NSLock()
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                try (index % 2 == 0 ? first : second).transaction { state, _ in state!.value += 1 }
            } catch { failureLock.lock(); errors.append(error); failureLock.unlock() }
        }
        XCTAssertTrue(errors.isEmpty, "Concurrent transaction failures: \(errors)")
        XCTAssertEqual(try first.read().value, 40)
        XCTAssertThrowsError(try second.transaction(expectedRevision: 1) { state, _ in state!.value = -1 }) {
            XCTAssertEqual($0 as? AccessError, .revisionConflict)
        }
        XCTAssertEqual(try second.read().value, 40)
    }

    func testThrowingTransactionPreservesPriorStateAndRejectsUnsupportedEnvelope() throws {
        let f = try VaultFixture(initialize: false)
        let store = try EncryptedAccessFile<Counter>(directory: f.directory, namespace: "counter", keyProvider: f.keys)
        try store.transaction(allowInitialization: true) { state, _ in state = Counter(value: 4) }
        XCTAssertThrowsError(try store.transaction { state, _ in state!.value = 99; throw AccessError.invalidTransition })
        XCTAssertEqual(try store.read().value, 4)
        let old = try JSONDecoder().decode(EncryptedAccessFile<Counter>.Envelope.self, from: Data(contentsOf: f.file))
        let future = EncryptedAccessFile<Counter>.Envelope(version: 2, revision: old.revision, ciphertext: old.ciphertext)
        try JSONEncoder().encode(future).write(to: f.file)
        XCTAssertThrowsError(try store.read()) { XCTAssertEqual($0 as? AccessError, .unsupportedVersion) }
    }
}
