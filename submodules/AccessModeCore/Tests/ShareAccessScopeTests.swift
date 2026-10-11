import XCTest
@testable import AccessModeCore

/// The share extension shows only what the PIN's mode may see: its accounts, its selected
/// account first, and lists without the chats hidden from it (plan §7: own PIN, shared policy).
final class ShareAccessScopeTests: XCTestCase {
    private let fixture = PolicyTests()

    private func observed(_ identity: AccountIdentity) -> ObservedAccount {
        ObservedAccount(environment: identity.environment, recordID: identity.recordID, userNamespace: 0, userID: identity.userID)
    }

    private var raw: [ObservedAccount] {
        [fixture.identity(3), fixture.identity(2), fixture.identity(1)].map { observed($0) }
    }

    func testBSeesItsAccountsWithTheSharedAccountsHiddenChats() throws {
        let policy = AccessModePolicy(mode: .b, configuration: try fixture.configuration())
        let scope = try policy.shareScope(observed: raw)
        XCTAssertEqual(scope.mode, .b)
        XCTAssertEqual(scope.recordIDs, [3, 1])
        XCTAssertEqual(scope.primaryRecordID, 1)
        XCTAssertEqual(scope.hiddenChats[1], [ChatIdentity(account: fixture.identity(1), peerNamespace: 0, peerID: 100)])
        XCTAssertNil(scope.hiddenChats[3])
        XCTAssertTrue(scope.redirectsRecentSearches)
    }

    func testASeesItsAccountsAndEveryChat() throws {
        let policy = AccessModePolicy(mode: .a, configuration: try fixture.configuration())
        let scope = try policy.shareScope(observed: raw)
        XCTAssertEqual(scope.recordIDs, [2, 1])
        XCTAssertEqual(scope.primaryRecordID, 1)
        XCTAssertTrue(scope.hiddenChats.isEmpty)
        XCTAssertFalse(scope.redirectsRecentSearches)
    }

    func testWithoutTheSelectedAccountThereIsNoScope() throws {
        let policy = AccessModePolicy(mode: .b, configuration: try fixture.configuration())
        XCTAssertThrowsError(try policy.shareScope(observed: [observed(fixture.identity(3))]))
    }

    func testAHiddenChatThatCannotBeNamedFailsClosed() throws {
        let primary = fixture.identity(1)
        let configuration = try AccessConfiguration(installation: fixture.installation, accounts: [
            AccountMembership(identity: primary, ownership: .shared)
        ], hiddenChats: [ChatIdentity(account: primary, peerNamespace: 0, peerID: 0x0100_0000_0000_0000)],
        selectedA: primary, selectedB: primary)
        let policy = AccessModePolicy(mode: .b, configuration: configuration)
        XCTAssertThrowsError(try policy.shareScope(observed: [observed(primary)]))
    }
}
