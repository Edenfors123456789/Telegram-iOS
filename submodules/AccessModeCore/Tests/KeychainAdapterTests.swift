#if os(iOS)
import XCTest
import Security
@testable import AccessModeCore

final class KeychainAdapterTests: XCTestCase {
    func testActualPresenceWitnessPersistsSeparatelyPerNamespaceAndCannotRepairCorruption() throws {
        let service = "org.negrfors.telegram.dualpin.presence-tests.\(UUID().uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        defer { SecItemDelete(query as CFDictionary) }
        let provider = try KeychainAccessDeviceKey(service: service)
        let key = try provider.loadKey(allowCreation: true)
        XCTAssertFalse(try provider.hasCommittedState(namespace: "test.vault"))
        try provider.recordCommittedState(namespace: "test.vault")
        try provider.recordCommittedState(namespace: "test.vault")
        let reopened = try KeychainAccessDeviceKey(service: service)
        XCTAssertTrue(try reopened.hasCommittedState(namespace: "test.vault"))
        XCTAssertFalse(try reopened.hasCommittedState(namespace: "test.transcripts"))
        try reopened.recordCommittedState(namespace: "test.transcripts")
        var all = query
        all[kSecReturnAttributes as String] = true
        all[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(all as CFDictionary, &result), errSecSuccess)
        let items = try XCTUnwrap(result as? [[String: Any]])
        let witnesses = items.filter { ($0[kSecAttrAccount as String] as? String)?.hasPrefix("dual-pin-state-presence.v1.") == true }
        XCTAssertEqual(witnesses.count, 2)
        for witness in witnesses {
            XCTAssertEqual(witness[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            XCTAssertEqual(witness[kSecAttrSynchronizable as String] as? Bool, false)
        }
        let damaged = Data("corrupt-isolated-witness".utf8)
        for witness in witnesses {
            var ownItem = query
            ownItem[kSecAttrAccount as String] = try XCTUnwrap(witness[kSecAttrAccount as String] as? String)
            XCTAssertEqual(SecItemUpdate(ownItem as CFDictionary, [kSecValueData as String: damaged] as CFDictionary), errSecSuccess)
        }
        XCTAssertThrowsError(try reopened.hasCommittedState(namespace: "test.vault")) { XCTAssertEqual($0 as? AccessError, .corrupt) }
        XCTAssertThrowsError(try reopened.recordCommittedState(namespace: "test.vault")) { XCTAssertEqual($0 as? AccessError, .corrupt) }
        XCTAssertThrowsError(try reopened.hasCommittedState(namespace: "test.transcripts"))
        XCTAssertEqual(try reopened.loadKey(allowCreation: false), key)
    }

    func testActualKeychainAdapterCreatesNonSynchronizingDeviceLocalItem() throws {
        let service = "org.negrfors.telegram.dualpin.tests.\(UUID().uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        defer { SecItemDelete(query as CFDictionary) }
        var plainRead = query
        plainRead[kSecReturnData as String] = true
        var plainResult: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(plainRead as CFDictionary, &plainResult), errSecItemNotFound,
                       "Plain non-biometric Keychain query must be available before testing the adapter")
        let provider = try KeychainAccessDeviceKey(service: service)
        XCTAssertThrowsError(try provider.loadKey(allowCreation: false)) { XCTAssertEqual($0 as? AccessError, .missingKey) }
        let first = try provider.loadKey(allowCreation: true)
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(try KeychainAccessDeviceKey(service: service).loadKey(allowCreation: false), first)
        var attributesQuery = query
        attributesQuery[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attributesQuery as CFDictionary, &attributes), errSecSuccess)
        let dictionary = try XCTUnwrap(attributes as? [String: Any])
        XCTAssertEqual(dictionary[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(dictionary[kSecAttrSynchronizable as String] as? Bool, false)
    }
}
#endif
