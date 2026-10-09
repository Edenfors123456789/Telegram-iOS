import XCTest
@testable import AccessModeCore

final class RuntimeBootstrapTests: XCTestCase {
    func testOnlyAbsentVaultCanContinueOrdinaryStartup() throws {
        let absent = try VaultFixture(initialize: false)
        if case .unconfigured = AccessRuntimeBootstrap.inspect({ absent.store }) {} else { XCTFail("Absent vault should permit initial setup") }
        let configured = try VaultFixture()
        guard case let .configured(store) = AccessRuntimeBootstrap.inspect({ configured.store }) else { return XCTFail("Configured vault must require mode authentication") }
        XCTAssertTrue(store === configured.store)
    }

    func testUnavailableKeyAndFactoryNeverFallBackToUnconfigured() throws {
        let f = try VaultFixture()
        f.keys.denied = true
        if case .unavailable = AccessRuntimeBootstrap.inspect({ f.store }) {} else { XCTFail("Keychain denial must require locking") }
        if case .unavailable = AccessRuntimeBootstrap.inspect({ throw AccessError.unavailable }) {} else { XCTFail("Factory failure must require locking") }
        f.keys.denied = false
        if case .configured = AccessRuntimeBootstrap.inspect({ f.store }) {} else { XCTFail("A later fresh probe should recover without resetting state") }
    }

    func testCorruptAndUnsupportedVaultCannotBecomeInitialSetup() throws {
        let f = try VaultFixture()
        let bytes = try Data(contentsOf: f.file)
        try Data("invalid".utf8).write(to: f.file)
        if case .unavailable = AccessRuntimeBootstrap.inspect({ f.store }) {} else { XCTFail("Corruption must deny startup") }
        let old = try JSONDecoder().decode(EncryptedAccessFile<AccessVaultState>.Envelope.self, from: bytes)
        let future = EncryptedAccessFile<AccessVaultState>.Envelope(version: 2, revision: old.revision, ciphertext: old.ciphertext)
        let futureBytes = try JSONEncoder().encode(future)
        try futureBytes.write(to: f.file)
        if case .unavailable = AccessRuntimeBootstrap.inspect({ f.store }) {} else { XCTFail("An unsupported version must deny startup") }
        XCTAssertEqual(try Data(contentsOf: f.file), futureBytes)
    }
}
