import Foundation
import XCTest
@testable import TelegramCore
import SwiftSignalKit

private final class PromotionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dual-pin-promotion-tests-\(UUID())")
    let manager: AccountManager<TelegramAccountManagerTypes>
    init() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        manager = AccountManager(basePath: directory.path, isTemporary: false, isReadOnly: false,
            useCaches: false, removeDatabaseOnError: true,
            accessChallenge: AccountManagerAccessChallenge(prepare: { _ in }, resolve: { _, _ in .some(.none) }, finishInitialization: {}))
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

final class AccountAuthorizationPromotionTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>) throws -> T {
        let done = expectation(description: "Promotion metadata result")
        var result: T?
        let disposable = signal.start(next: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        disposable.dispose()
        return try XCTUnwrap(result)
    }

    func testLegacyAuthWithoutEnvironmentAllowsOnlyProductionPromotion() throws {
        let f = try PromotionFixture()
        let id = try XCTUnwrap(value(f.manager.transaction { $0.createAuth([])?.id }))
        XCTAssertFalse(try value(f.manager.transaction {
            switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: true, isSupportUser: false)
        }))
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrentAuth()?.id }), id)
        XCTAssertTrue(try value(f.manager.transaction {
            switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: false, isSupportUser: false)
        }))
        XCTAssertEqual(try value(f.manager.transaction { $0.getCurrent()?.0 }), id)
    }

    func testConflictingEnvironmentAttributesCannotAuthorizePromotion() throws {
        let f = try PromotionFixture()
        let id = try XCTUnwrap(value(f.manager.transaction { $0.createAuth([
            .environment(AccountEnvironmentAttribute(environment: .production)),
            .environment(AccountEnvironmentAttribute(environment: .test))
        ])?.id }))
        XCTAssertFalse(try value(f.manager.transaction {
            switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: true, isSupportUser: false)
        }))
        _ = try value(f.manager.transaction { transaction -> Void in
            XCTAssertTrue(transaction.getRecords().isEmpty)
            XCTAssertEqual(transaction.getCurrentAuth()?.id, id)
            XCTAssertNil(transaction.getCurrent())
        })
    }

    func testMatchingAuthPromotesOnceWithItsEnvironmentAndSupportAttribute() throws {
        let f = try PromotionFixture()
        let id = try XCTUnwrap(value(f.manager.transaction { $0.createAuth([.environment(AccountEnvironmentAttribute(environment: .test))])?.id }))
        XCTAssertTrue(try value(f.manager.transaction {
            switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: true, isSupportUser: true)
        }))
        _ = try value(f.manager.transaction { transaction -> Void in
            XCTAssertNil(transaction.getCurrentAuth())
            XCTAssertEqual(transaction.getCurrent()?.0, id)
            let record = transaction.getRecords().first { $0.id == id }
            XCTAssertNil(record?.temporarySessionId)
            XCTAssertTrue(record?.attributes.contains { if case let .environment(e) = $0 { return e.environment == .test }; return false } == true)
            XCTAssertTrue(record?.attributes.contains { if case .supportUserInfo = $0 { return true }; return false } == true)
        })
        XCTAssertFalse(try value(f.manager.transaction {
            switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: true, isSupportUser: false)
        }))
        _ = try value(f.manager.transaction { transaction -> Void in
            XCTAssertTrue(transaction.getRecords().first { $0.id == id }?.attributes.contains { if case .supportUserInfo = $0 { return true }; return false } == true)
        })
    }

    func testMissingAuthCannotCreateARecordOrChangeCurrentAccount() throws {
        let f = try PromotionFixture()
        let existing = try value(f.manager.transaction { transaction -> AccountRecordId in
            let id = transaction.createRecord([])
            transaction.setCurrentId(id)
            return id
        })
        let stale = AccountRecordId(rawValue: 77)
        XCTAssertFalse(try value(f.manager.transaction {
            switchAuthorizationRecord(transaction: $0, id: stale, testingEnvironment: false, isSupportUser: false)
        }))
        _ = try value(f.manager.transaction { transaction -> Void in
            XCTAssertEqual(transaction.getRecords().map { $0.id }, [existing])
            XCTAssertEqual(transaction.getCurrent()?.0, existing)
            XCTAssertNil(transaction.getCurrentAuth())
        })
    }

    func testOldCompletionPreservesTheReplacementAuthAndExistingAccount() throws {
        let f = try PromotionFixture()
        let ids = try value(f.manager.transaction { transaction -> (AccountRecordId, AccountRecordId, AccountRecordId) in
            let existing = transaction.createRecord([])
            transaction.setCurrentId(existing)
            let old = transaction.createAuth([])!.id
            let replacement = transaction.createAuth([.environment(AccountEnvironmentAttribute(environment: .test))])!.id
            return (existing, old, replacement)
        })
        XCTAssertFalse(try value(f.manager.transaction {
            switchAuthorizationRecord(transaction: $0, id: ids.1, testingEnvironment: false, isSupportUser: false)
        }))
        _ = try value(f.manager.transaction { transaction -> Void in
            XCTAssertEqual(transaction.getRecords().map { $0.id }, [ids.0])
            XCTAssertEqual(transaction.getCurrent()?.0, ids.0)
            XCTAssertEqual(transaction.getCurrentAuth()?.id, ids.2)
        })
    }

    func testWrongEnvironmentCannotPromoteOrRemoveItsCurrentAuth() throws {
        for testing in [false, true] {
            let f = try PromotionFixture()
            let id = try XCTUnwrap(value(f.manager.transaction { $0.createAuth([.environment(AccountEnvironmentAttribute(environment: testing ? .test : .production))])?.id }))
            XCTAssertFalse(try value(f.manager.transaction {
                switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: !testing, isSupportUser: false)
            }))
            _ = try value(f.manager.transaction { transaction -> Void in
                XCTAssertTrue(transaction.getRecords().isEmpty)
                XCTAssertEqual(transaction.getCurrentAuth()?.id, id)
                XCTAssertNil(transaction.getCurrent())
            })
        }
    }

    func testCollisionWithAnExistingRecordCannotOverwriteThatRecord() throws {
        let f = try PromotionFixture()
        let id = try XCTUnwrap(value(f.manager.transaction { transaction -> AccountRecordId? in
            guard let auth = transaction.createAuth([]) else { return nil }
            transaction.updateRecord(auth.id, { _ in AccountRecord(id: auth.id, attributes: [.sortOrder(AccountSortOrderAttribute(order: 42))], temporarySessionId: nil) })
            transaction.setCurrentId(auth.id)
            return auth.id
        }))
        XCTAssertFalse(try value(f.manager.transaction {
            switchAuthorizationRecord(transaction: $0, id: id, testingEnvironment: false, isSupportUser: true)
        }))
        _ = try value(f.manager.transaction { transaction -> Void in
            XCTAssertEqual(transaction.getCurrentAuth()?.id, id)
            XCTAssertEqual(transaction.getCurrent()?.0, id)
            XCTAssertEqual(transaction.getRecords().count, 1)
            XCTAssertTrue(transaction.getRecords().first?.attributes.contains { if case let .sortOrder(s) = $0 { return s.order == 42 }; return false } == true)
            XCTAssertFalse(transaction.getRecords().first?.attributes.contains { if case .supportUserInfo = $0 { return true }; return false } == true)
        })
    }
}
