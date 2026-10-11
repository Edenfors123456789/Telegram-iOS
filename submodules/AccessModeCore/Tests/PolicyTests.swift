import XCTest
@testable import AccessModeCore

final class PolicyTests: XCTestCase {
    let installation = UUID()

    func identity(_ record: Int64, user: Int64? = nil) -> AccountIdentity {
        AccountIdentity(installation: installation, environment: .production, recordID: record, userID: user ?? record)
    }

    func configuration(hidden: Bool = true) throws -> AccessConfiguration {
        let primary = identity(1)
        return try AccessConfiguration(installation: installation, accounts: [
            AccountMembership(identity: primary, ownership: .shared),
            AccountMembership(identity: identity(2), ownership: .a),
            AccountMembership(identity: identity(3), ownership: .b)
        ], hiddenChats: hidden ? [ChatIdentity(account: primary, peerNamespace: 0, peerID: 100)] : [],
        selectedA: primary, selectedB: primary)
    }

    func testBothPoolsHideOtherRolesAccounts() throws {
        let config = try configuration()
        XCTAssertEqual(AccessModePolicy(mode: .a, configuration: config).visibleAccounts, [identity(1), identity(2)])
        XCTAssertEqual(AccessModePolicy(mode: .b, configuration: config).visibleAccounts, [identity(1), identity(3)])
    }

    func testHiddenDiscoveryAndExplicitOpeningAreDifferentPermissions() throws {
        let chat = ChatIdentity(account: identity(1), peerNamespace: 0, peerID: 100)
        let config = try configuration()
        let a = AccessModePolicy(mode: .a, configuration: config)
        let b = AccessModePolicy(mode: .b, configuration: config)
        XCTAssertTrue(a.discover(chat))
        XCTAssertEqual(a.explicitOpen(chat), .ordinary)
        XCTAssertFalse(b.discover(chat))
        XCTAssertEqual(b.explicitOpen(chat), .restrictedTranscript)
        XCTAssertFalse(b.canManageHiddenChats)
        XCTAssertFalse(a.allowsPush)
        XCTAssertFalse(b.allowsBiometrics)
    }

    func testListsInBExcludeExactlyTheChatsDiscoveryRefuses() throws {
        let primary = identity(1)
        let hidden = [ChatIdentity(account: primary, peerNamespace: 0, peerID: 100), ChatIdentity(account: primary, peerNamespace: 2, peerID: 7)]
        let config = try AccessConfiguration(installation: installation, accounts: [
            AccountMembership(identity: primary, ownership: .shared),
            AccountMembership(identity: identity(2), ownership: .a),
            AccountMembership(identity: identity(3), ownership: .b)
        ], hiddenChats: Set(hidden), selectedA: primary, selectedB: primary)
        let a = AccessModePolicy(mode: .a, configuration: config)
        let b = AccessModePolicy(mode: .b, configuration: config)
        XCTAssertEqual(Set(b.undiscoverableChats(of: primary)), Set(hidden))
        XCTAssertTrue(b.undiscoverableChats(of: primary).allSatisfy { !b.discover($0) })
        XCTAssertEqual(a.undiscoverableChats(of: primary), [], "A lists every chat")
        XCTAssertEqual(b.undiscoverableChats(of: identity(3)), [], "B's own account has no hidden chats")
        XCTAssertEqual(b.undiscoverableChats(of: identity(2)), [], "an account B cannot see has no lists in B")
        XCTAssertEqual(b.undiscoverableChats(of: identity(1, user: 999)), [], "a replaced account matches nothing")
    }

    func testUnknownOrReplacedAccountAndNamespaceAreDenied() throws {
        let b = AccessModePolicy(mode: .b, configuration: try configuration())
        for account in [identity(2), identity(99), identity(1, user: 999)] {
            let chat = ChatIdentity(account: account, peerNamespace: 0, peerID: 100)
            XCTAssertFalse(b.discover(chat))
            XCTAssertEqual(b.explicitOpen(chat), .denied)
        }
        XCTAssertEqual(b.explicitOpen(ChatIdentity(account: identity(1), peerNamespace: 42, peerID: 100)), .denied)
    }

    func testMalformedConfigurationDoesNotFallBackToRawAccounts() throws {
        XCTAssertThrowsError(try AccessConfiguration(installation: installation, accounts: [], selectedA: identity(1), selectedB: identity(1)))
        XCTAssertThrowsError(try AccessConfiguration(installation: installation, accounts: [
            AccountMembership(identity: identity(1), ownership: .shared),
            AccountMembership(identity: identity(2, user: 1), ownership: .b)
        ], selectedA: identity(1), selectedB: identity(1)))
        XCTAssertThrowsError(try AccessConfiguration(installation: installation, accounts: [
            AccountMembership(identity: identity(1), ownership: .shared), AccountMembership(identity: identity(2), ownership: .a)
        ], selectedA: identity(1), selectedB: identity(2)))
    }

    func testPremiumFromHiddenPoolDoesNotIncreaseOtherPoolsLimit() {
        let members = [AccountMembership(identity: identity(1), ownership: .shared)] +
            (2 ... 4).map { AccountMembership(identity: identity(Int64($0)), ownership: .b) } +
            [AccountMembership(identity: identity(5), ownership: .a, isPremium: true)]
        XCTAssertThrowsError(try AccessConfiguration(installation: installation, accounts: members, selectedA: identity(1), selectedB: identity(1)))
    }

    func testSymmetricAccountCollisionCannotRevealOrTransferHiddenAccount() throws {
        let config = try configuration()
        let a = AccessModePolicy(mode: .a, configuration: config)
        let b = AccessModePolicy(mode: .b, configuration: config)
        XCTAssertEqual(a.enrollment(environment: .production, userID: 3, isPremium: false), .unavailable)
        XCTAssertEqual(b.enrollment(environment: .production, userID: 2, isPremium: true), .unavailable)
        XCTAssertEqual(b.enrollment(environment: .production, userID: 1, isPremium: false), .existingVisible(identity(1)))
        XCTAssertEqual(a.enrollment(environment: .production, userID: 9, isPremium: false), .new(.a))
        XCTAssertEqual(b.enrollment(environment: .production, userID: 9, isPremium: false), .new(.b))
    }

    func testSevenRawAccountsAndOrdinaryBHistoryRemainSupported() throws {
        let members = [AccountMembership(identity: identity(1), ownership: .shared, isPremium: true)] +
            (2 ... 4).map { AccountMembership(identity: identity(Int64($0)), ownership: .a) } +
            (5 ... 7).map { AccountMembership(identity: identity(Int64($0)), ownership: .b) }
        let config = try AccessConfiguration(installation: installation, accounts: members, selectedA: identity(2), selectedB: identity(5))
        let b = AccessModePolicy(mode: .b, configuration: config)
        XCTAssertEqual(b.visibleAccounts.count, 4)
        XCTAssertEqual(b.explicitOpen(ChatIdentity(account: identity(5), peerNamespace: 0, peerID: 100)), .ordinary)
        XCTAssertEqual(b.explicitOpen(ChatIdentity(account: identity(1), peerNamespace: 0, peerID: 100)), .ordinary)
        XCTAssertEqual(b.enrollment(environment: .production, userID: 9, isPremium: true), .unavailable)
    }
}
