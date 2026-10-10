import XCTest
@testable import AccessModeCore

final class InitialAccountsTests: XCTestCase {
    func testCompleteIndependentRecordMetadataPermitsConfirmedPool() throws {
        let loaded = [account(10), account(-20, user: 20, environment: .test)]
        let records = [InitialAccountRecord(recordID: -20, environment: .test), InitialAccountRecord(recordID: 10, environment: .production)]
        let config = try AccessConfiguration.initial(installation: UUID(), records: records, hasPendingAuthorization: false,
            accounts: loaded, sharedAccount: loaded[0].observed)
        XCTAssertEqual(config.accounts.map(\.identity.recordID), [10, -20])
        XCTAssertEqual(config.accounts.map(\.ownership), [.shared, .a])
    }

    func testMissingLoadedPeerGhostRowWrongEnvironmentAndDuplicateSourceRecordsDenySetup() throws {
        let loaded = [account(10)]
        let correct = InitialAccountRecord(recordID: 10, environment: .production)
        for records in [[correct, InitialAccountRecord(recordID: 20, environment: .production)], [],
                        [InitialAccountRecord(recordID: 99, environment: .production)],
                        [InitialAccountRecord(recordID: 10, environment: .test)], [correct, correct],
                        [correct, InitialAccountRecord(recordID: 10, environment: .test)]] {
            XCTAssertThrowsError(try AccessConfiguration.initial(installation: UUID(), records: records, hasPendingAuthorization: false,
                accounts: loaded, sharedAccount: loaded[0].observed))
        }
    }

    func testPendingAuthorizationCannotPublishInitialPoolEvenWhenAllOtherPeersAreLoaded() throws {
        let loaded = [account(10)]
        XCTAssertThrowsError(try AccessConfiguration.initial(installation: UUID(),
            records: [InitialAccountRecord(recordID: 10, environment: .production)], hasPendingAuthorization: true,
            accounts: loaded, sharedAccount: loaded[0].observed))
    }

    private func account(_ record: Int64, user: Int64? = nil, environment: AccountEnvironment = .production,
                         namespace: Int32 = 0, premium: Bool = false) -> InitialSetupAccount {
        InitialSetupAccount(observed: ObservedAccount(environment: environment, recordID: record,
            userNamespace: namespace, userID: user ?? record), isPremium: premium)
    }

    // Self/ownership/limits fixtures are complete by construction. The source
    // completeness tests above provide independent expected record metadata.
    private func valuePool(installation: UUID, accounts: [InitialSetupAccount], sharedAccount: ObservedAccount) throws -> AccessConfiguration {
        try AccessConfiguration.initial(installation: installation,
            records: accounts.map { InitialAccountRecord(recordID: $0.observed.recordID, environment: $0.observed.environment) },
            hasPendingAuthorization: false, accounts: accounts, sharedAccount: sharedAccount)
    }

    func testSelectedSharedAccountIsExactAndAllOtherExistingAccountsBelongOnlyToA() throws {
        let records = [account(10), account(20), account(30)]
        let installation = UUID()
        let config = try valuePool(installation: installation, accounts: records, sharedAccount: records[1].observed)
        XCTAssertEqual(config.accounts.map(\.identity.recordID), [10, 20, 30])
        XCTAssertEqual(config.accounts.map(\.ownership), [.a, .shared, .a])
        XCTAssertEqual(config.selectedA, config.selectedB)
        XCTAssertEqual(config.selectedB.recordID, 20)
        XCTAssertTrue(config.accounts.allSatisfy { $0.identity.installation == installation })
        XCTAssertTrue(config.hiddenChats.isEmpty)
        XCTAssertEqual(AccessModePolicy(mode: .a, configuration: config).visibleAccounts.count, 3)
        XCTAssertEqual(AccessModePolicy(mode: .b, configuration: config).visibleAccounts, [config.selectedB])
    }

    func testInvalidOrIncompleteSelfIdentityCannotBeOmittedOrSubstitutedByRecordID() throws {
        let valid = account(10)
        for records in [[], [valid, account(20, namespace: 1)], [valid, account(20, user: 0)],
                        [valid, account(10, user: 20)], [valid, account(20, user: 10)]] {
            XCTAssertThrowsError(try valuePool(installation: UUID(), accounts: records, sharedAccount: valid.observed))
        }
        for wrong in [account(10, user: 999), account(10, environment: .test), account(99)] {
            XCTAssertThrowsError(try valuePool(installation: UUID(), accounts: [valid], sharedAccount: wrong.observed))
        }
    }

    func testFourInitialAAccountsRequirePremiumInThatVisiblePool() throws {
        let records = [account(10), account(20), account(30), account(40)]
        XCTAssertThrowsError(try valuePool(installation: UUID(), accounts: records, sharedAccount: records[0].observed))
        let premium = records.dropLast() + [account(40, premium: true)]
        let config = try valuePool(installation: UUID(), accounts: Array(premium), sharedAccount: records[0].observed)
        XCTAssertEqual(config.accounts.last?.isPremium, true)
        XCTAssertEqual(AccessModePolicy(mode: .a, configuration: config).visibleAccounts.count, 4)
        XCTAssertEqual(AccessModePolicy(mode: .b, configuration: config).visibleAccounts, [config.selectedB])
    }

    func testSignedRecordIDsAndEqualServerIDsInDifferentEnvironmentsArePreserved() throws {
        let records = [account(-12, user: 50), account(99, user: 50, environment: .test)]
        let config = try valuePool(installation: UUID(), accounts: records, sharedAccount: records[0].observed)
        XCTAssertEqual(config.accounts.map(\.identity.recordID), [-12, 99])
        XCTAssertEqual(config.accounts.map(\.identity.environment), [.production, .test])
        XCTAssertEqual(config.accounts.map(\.identity.userID), [50, 50])
    }
}
