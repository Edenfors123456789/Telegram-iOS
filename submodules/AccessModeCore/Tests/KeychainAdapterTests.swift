#if os(iOS)
import XCTest
import Security
@testable import AccessModeCore

final class KeychainAdapterTests: XCTestCase {
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
