import XCTest
@testable import AccessModeCore

/// Push is disabled in both modes; registrations made by earlier builds are cancelled on the
/// server, and an entry leaves the ledger only on the server's answer.
final class PushRegistrationCleanupTests: XCTestCase {
    private typealias Ledger = PushRegistrationCleanupLedger

    func testTheFirstLaunchMakesEverySignedInAccountPendingForBothTokenTypes() {
        let ledger = Ledger.load(nil, signedInAccounts: [1, 2])
        XCTAssertEqual(ledger.pendingTypes(account: 1), [.aps, .voip])
        XCTAssertEqual(ledger.pendingTypes(account: 2), [.aps, .voip])
        XCTAssertFalse(ledger.isEmpty)
    }

    func testAFreshInstallHasNothingToCancel() {
        XCTAssertTrue(Ledger.load(nil, signedInAccounts: []).isEmpty)
    }

    func testAnAccountSignedInAfterTheFirstLaunchNeverEntersTheLedger() throws {
        let stored = try Ledger.load(nil, signedInAccounts: [1]).encoded()
        let ledger = Ledger.load(stored, signedInAccounts: [1, 3])
        XCTAssertEqual(ledger.pendingTypes(account: 3), [])
        XCTAssertEqual(ledger.pendingTypes(account: 1), [.aps, .voip])
    }

    func testAnAcknowledgedTypeLeavesAndTheRestStays() throws {
        var ledger = Ledger.load(nil, signedInAccounts: [1])
        ledger.acknowledge(account: 1, type: .aps)
        XCTAssertEqual(ledger.pendingTypes(account: 1), [.voip])
        let reloaded = Ledger.load(try ledger.encoded(), signedInAccounts: [1])
        XCTAssertEqual(reloaded.pendingTypes(account: 1), [.voip])
        var finished = reloaded
        finished.acknowledge(account: 1, type: .voip)
        XCTAssertTrue(finished.isEmpty)
    }

    func testAnEmptyLedgerStaysEmptyAcrossLaunches() throws {
        var ledger = Ledger.load(nil, signedInAccounts: [1])
        ledger.acknowledge(account: 1, type: .aps)
        ledger.acknowledge(account: 1, type: .voip)
        XCTAssertTrue(Ledger.load(try ledger.encoded(), signedInAccounts: [1, 2]).isEmpty)
    }

    func testAnAccountNoLongerSignedInLeaves() throws {
        let stored = try Ledger.load(nil, signedInAccounts: [1, 2]).encoded()
        let ledger = Ledger.load(stored, signedInAccounts: [2])
        XCTAssertEqual(ledger.pendingTypes(account: 1), [])
        XCTAssertEqual(ledger.pendingTypes(account: 2), [.aps, .voip])
    }

    func testUnreadableStorageCancelsForEverySignedInAccountAgain() {
        // Cancelling a registration that no longer exists is harmless; missing one is not.
        let ledger = Ledger.load(Data("not a ledger".utf8), signedInAccounts: [4])
        XCTAssertEqual(ledger.pendingTypes(account: 4), [.aps, .voip])
    }
}
