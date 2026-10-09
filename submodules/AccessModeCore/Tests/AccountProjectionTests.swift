import XCTest
@testable import AccessModeCore

final class AccountProjectionTests: XCTestCase {
    func observed(_ identity: AccountIdentity, namespace: Int32 = 0) -> ObservedAccount {
        ObservedAccount(environment: identity.environment, recordID: identity.recordID,
                        userNamespace: namespace, userID: identity.userID)
    }

    func testProjectionPreservesVisibleOrderAndDoesNotPublishOtherRoleOrUnknownRecords() throws {
        let fixture = PolicyTests()
        let configuration = try fixture.configuration()
        let raw = [fixture.identity(3), fixture.identity(99), fixture.identity(2), fixture.identity(1)]
        let a = try AccessModePolicy(mode: .a, configuration: configuration).projectAccounts(raw.map { observed($0) })
        let b = try AccessModePolicy(mode: .b, configuration: configuration).projectAccounts(raw.map { observed($0) })
        XCTAssertEqual(a.accounts, [fixture.identity(2), fixture.identity(1)])
        XCTAssertEqual(b.accounts, [fixture.identity(3), fixture.identity(1)])
        XCTAssertEqual(a.primary, fixture.identity(1))
        XCTAssertEqual(b.primary, fixture.identity(1))
    }

    func testMissingSelectionNeverFallsBackToFirstRawOrFirstVisibleAccount() throws {
        let fixture = PolicyTests()
        let policy = AccessModePolicy(mode: .a, configuration: try fixture.configuration())
        let result = try policy.projectAccounts([observed(fixture.identity(3)), observed(fixture.identity(2))])
        XCTAssertEqual(result.accounts, [fixture.identity(2)])
        XCTAssertNil(result.primary)
        XCTAssertEqual(try policy.projectAccounts([]).accounts, [])
        XCTAssertNil(try policy.projectAccounts([]).primary)
    }

    func testReusedRecordWrongEnvironmentOrNonUserIdentityCannotInheritAccess() throws {
        let fixture = PolicyTests()
        let policy = AccessModePolicy(mode: .a, configuration: try fixture.configuration())
        for raw in [
            ObservedAccount(environment: .production, recordID: 1, userNamespace: 0, userID: 999),
            ObservedAccount(environment: .test, recordID: 1, userNamespace: 0, userID: 1),
            observed(fixture.identity(1), namespace: 1),
            ObservedAccount(environment: .production, recordID: 1, userNamespace: 0, userID: 0),
            ObservedAccount(environment: .production, recordID: 90, userNamespace: 0, userID: 1)
        ] {
            let result = try policy.projectAccounts([raw])
            XCTAssertNil(result.primary)
            XCTAssertTrue(result.accounts.isEmpty)
        }
    }

    func testAmbiguousRawRecordsAndServerIdentityDuplicatesFailClosed() throws {
        let fixture = PolicyTests()
        let policy = AccessModePolicy(mode: .a, configuration: try fixture.configuration())
        let primary = observed(fixture.identity(1))
        for raw in [
            [primary, primary],
            [primary, ObservedAccount(environment: .test, recordID: 1, userNamespace: 0, userID: 3)],
            [primary, ObservedAccount(environment: .production, recordID: 50, userNamespace: 0, userID: 1)]
        ] {
            XCTAssertThrowsError(try policy.projectAccounts(raw))
        }
    }

    func testTestAndProductionUsersWithSameNumberRemainDifferentAccounts() throws {
        let fixture = PolicyTests()
        let prod = fixture.identity(1)
        let test = AccountIdentity(installation: prod.installation, environment: .test, recordID: 2, userID: 1)
        let configuration = try AccessConfiguration(installation: prod.installation, accounts: [
            AccountMembership(identity: prod, ownership: .shared),
            AccountMembership(identity: test, ownership: .b)
        ], selectedA: prod, selectedB: test)
        let raw = [observed(test), observed(prod)]
        XCTAssertEqual(try AccessModePolicy(mode: .a, configuration: configuration).projectAccounts(raw).accounts, [prod])
        XCTAssertEqual(try AccessModePolicy(mode: .b, configuration: configuration).projectAccounts(raw).primary, test)
    }
}
