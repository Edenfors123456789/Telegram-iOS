import XCTest
@testable import AccessModeCore

final class InitializationTests: XCTestCase {
    func testInitialOwnerPreparationFailureDoesNotPublishEitherPINOrReplaceExistingVault() throws {
        let f = try VaultFixture(initialize: false)
        XCTAssertFalse(try f.store.isConfigured())
        var calls = 0
        XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321", prepareProtectedResources: {
            calls += 1
            throw AccessError.authenticationRequired
        }))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(try f.store.isConfigured())
        XCTAssertThrowsError(try f.store.authenticate(pin: "654321"))
        try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "654321", prepareProtectedResources: { calls += 1 })
        XCTAssertTrue(try f.store.isConfigured())
        XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "111111", pinB: "222222", prepareProtectedResources: { calls += 1 }))
        XCTAssertEqual(calls, 2)
        f.keys.denied = true
        XCTAssertThrowsError(try f.store.isConfigured())
    }

    func testInvalidCodesCannotChangeLegacyResources() throws {
        let f = try VaultFixture(initialize: false)
        var called = false
        XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "1234", pinB: "654321", prepareProtectedResources: { called = true }))
        XCTAssertThrowsError(try f.store.initialize(configuration: f.config, pinA: "123456", pinB: "123456", prepareProtectedResources: { called = true }))
        XCTAssertFalse(called)
        XCTAssertFalse(try f.store.isConfigured())
    }
}
