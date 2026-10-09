import XCTest
@testable import AccessModeCore

final class PINRequestTests: XCTestCase {
    func testQueuedPINCannotStartAfterSynchronousLockOrReuseAConsumedRequest() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let queued = try coordinator.preparePINRequest()
        try coordinator.lock()
        XCTAssertThrowsError(try coordinator.beginUnlock(pin: "123456", request: queued))
        XCTAssertEqual(coordinator.state, .locked)
        let request = try coordinator.preparePINRequest()
        let verified = try coordinator.beginUnlock(pin: "654321", request: request)
        XCTAssertThrowsError(try coordinator.beginUnlock(pin: "123456", request: request))
        XCTAssertEqual(coordinator.state, .preparing(.b))
        try coordinator.completePreparation(verified)
        XCTAssertEqual(try coordinator.withPolicy(verified) { $0.mode }, .b)
    }

    func testAbandonedPINResultCancelsOnlyItsOwnPreparation() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        let a = try coordinator.beginUnlock(pin: "123456")
        let b = try coordinator.beginUnlock(pin: "654321")
        try coordinator.cancelPreparation(a)
        XCTAssertEqual(coordinator.state, .preparing(.b))
        try coordinator.cancelPreparation(b)
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertThrowsError(try coordinator.completePreparation(b))
        let current = try coordinator.beginUnlock(pin: "123456")
        try coordinator.completePreparation(current)
        XCTAssertThrowsError(try coordinator.cancelPreparation(current))
        XCTAssertEqual(coordinator.state, .active(.a))
    }

    func testCooldownDoesNotExposeBlockedAOrDisablePermittedBAndPersistsRebootDelay() throws {
        let f = try VaultFixture()
        let coordinator = AccessModeCoordinator(store: f.store)
        for _ in 0 ..< 5 { XCTAssertThrowsError(try coordinator.beginUnlock(pin: "111111")) }
        _ = try coordinator.beginUnlock(pin: "654321")
        XCTAssertThrowsError(try coordinator.beginUnlock(pin: "111111"))
        XCTAssertEqual(try coordinator.cooldownRemaining(), 0)
        for _ in 0 ..< 5 { XCTAssertThrowsError(try coordinator.beginUnlock(pin: "111111")) }
        XCTAssertEqual(try coordinator.cooldownRemaining(), 60)
        f.clock.uptime += 20
        XCTAssertEqual(try coordinator.cooldownRemaining(), 40)
        f.clock.boot = "boot-2"
        f.clock.uptime = 1
        XCTAssertEqual(try coordinator.cooldownRemaining(), 60)
        f.clock.uptime = 62
        XCTAssertEqual(try coordinator.cooldownRemaining(), 0)
        _ = try coordinator.beginUnlock(pin: "123456")
        XCTAssertEqual(coordinator.state, .preparing(.a))
    }
}
