import XCTest
@testable import AccessModeCore

final class AccountPublicationGateTests: XCTestCase {
    func testInitialPreparationQuarantinesQueuedRawAccountsUntilExactAbsentOutcome() throws {
        let gate = AccessAccountPublicationGate()
        let queuedAccountNames = ["private-account"]
        let deliver = { gate.requiresModePolicy ? [] : queuedAccountNames }
        XCTAssertEqual(deliver(), queuedAccountNames)
        let ticket = try gate.beginInitialPreparation()
        XCTAssertTrue(gate.requiresModePolicy)
        XCTAssertEqual(deliver(), [])
        try gate.restoreConfirmedUnconfigured(ticket)
        XCTAssertFalse(gate.requiresModePolicy)
        XCTAssertEqual(deliver(), queuedAccountNames)
        XCTAssertThrowsError(try gate.restoreConfirmedUnconfigured(ticket))
    }

    func testForeignAndReplayedTicketCannotRevealNewPreparation() throws {
        let gate = AccessAccountPublicationGate()
        let foreign = try AccessAccountPublicationGate().beginInitialPreparation()
        let first = try gate.beginInitialPreparation()
        XCTAssertThrowsError(try gate.restoreConfirmedUnconfigured(foreign))
        XCTAssertTrue(gate.requiresModePolicy)
        try gate.restoreConfirmedUnconfigured(first)
        let second = try gate.beginInitialPreparation()
        XCTAssertThrowsError(try gate.restoreConfirmedUnconfigured(first))
        XCTAssertTrue(gate.requiresModePolicy)
        try gate.restoreConfirmedUnconfigured(second)
        XCTAssertFalse(gate.requiresModePolicy)
    }

    func testConcurrentInitialPreparationCannotReplaceOutstandingTicket() throws {
        let gate = AccessAccountPublicationGate()
        let ticket = try gate.beginInitialPreparation()
        XCTAssertThrowsError(try gate.beginInitialPreparation())
        XCTAssertTrue(gate.requiresModePolicy)
        try gate.restoreConfirmedUnconfigured(ticket)
        XCTAssertFalse(gate.requiresModePolicy)
    }

    func testConfiguredOrUnavailableOutcomePermanentlyDeniesRawAndLateAbsentCallback() throws {
        let gate = AccessAccountPublicationGate()
        let ticket = try gate.beginInitialPreparation()
        gate.requireModePolicy()
        XCTAssertTrue(gate.requiresModePolicy)
        XCTAssertThrowsError(try gate.restoreConfirmedUnconfigured(ticket))
        XCTAssertThrowsError(try gate.beginInitialPreparation())
        gate.requireModePolicy()
        XCTAssertTrue(gate.requiresModePolicy)
        let startup = AccessAccountPublicationGate(modeRequired: true)
        XCTAssertTrue(startup.requiresModePolicy)
        XCTAssertThrowsError(try startup.beginInitialPreparation())
        XCTAssertThrowsError(try startup.restoreConfirmedUnconfigured(ticket))
    }
}
