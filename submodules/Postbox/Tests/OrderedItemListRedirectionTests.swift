import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// While `Postbox.addOrderedItemListRedirection(from:to:)` is held, every read and write of the
/// list goes to another one (Dual PIN keeps the restricted mode's recent searches apart from
/// the full mode's). The original list is untouched and returns on release.
final class OrderedItemListRedirectionTests: XCTestCase {
    private var fixture: PostboxFixture!
    private let list: Int32 = 2
    private let separate: Int32 = 1002

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "OrderedItemListRedirectionTests")
    }

    override func tearDown() {
        self.fixture.close()
        self.fixture = nil
        super.tearDown()
    }

    private func entry(_ value: UInt8) -> OrderedItemListEntry {
        let data = Data([value])
        return OrderedItemListEntry(id: MemoryBuffer(data: data), contents: CodableEntry(data: data))
    }

    private func add(_ value: UInt8, to list: Int32? = nil) {
        self.fixture.transaction { transaction in
            transaction.addOrMoveToFirstPositionOrderedItemListItem(collectionId: list ?? self.list, item: self.entry(value), removeTailIfCountExceeds: nil)
        }
    }

    private func items(_ list: Int32? = nil) -> [UInt8] {
        return (self.fixture.transaction { transaction in
            transaction.getOrderedListItems(collectionId: list ?? self.list).map { $0.id.makeData().first ?? 0 }
        }) ?? []
    }

    private func viewed() -> [UInt8] {
        let recorder = self.fixture.observe(.orderedItemList(id: self.list), as: OrderedItemListView.self)
        return (recorder.waitForValues(count: 1).last?.items ?? []).map { $0.id.makeData().first ?? 0 }
    }

    private func redirect() -> Disposable {
        let disposable = self.fixture.postbox.addOrderedItemListRedirection(from: self.list, to: self.separate)
        self.fixture.transaction { _ in }
        return disposable
    }

    func testAReaderCanTellThatAListIsRedirected() {
        // Server sync of a recents list must not write the full mode's list into the
        // restricted mode's one, so it asks first.
        XCTAssertEqual(self.fixture.transaction { $0.isOrderedItemListRedirected(collectionId: self.list) }, false)
        let disposable = self.redirect()
        XCTAssertEqual(self.fixture.transaction { $0.isOrderedItemListRedirected(collectionId: self.list) }, true)
        XCTAssertEqual(self.fixture.transaction { $0.isOrderedItemListRedirected(collectionId: self.separate) }, false)
        disposable.dispose()
        let deadline = Date().addingTimeInterval(5.0)
        while self.fixture.transaction({ $0.isOrderedItemListRedirected(collectionId: self.list) }) == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(self.fixture.transaction { $0.isOrderedItemListRedirected(collectionId: self.list) }, false)
    }

    func testARedirectedListIsReadAndWrittenSeparately() {
        self.add(1)
        let redirection = self.redirect()
        XCTAssertEqual(self.items(), [], "the full mode's entries are not visible")
        XCTAssertEqual(self.viewed(), [])
        self.add(2)
        XCTAssertEqual(self.items(), [2])
        XCTAssertEqual(self.viewed(), [2])
        redirection.dispose()
        self.fixture.transaction { _ in }
        XCTAssertEqual(self.items(), [1], "the original list is untouched")
        XCTAssertEqual(self.viewed(), [1])
        XCTAssertEqual(self.items(self.separate), [2], "the separate list keeps its entries")
    }

    func testAViewFollowsWritesUnderTheRedirection() {
        let redirection = self.redirect()
        let recorder = self.fixture.observe(.orderedItemList(id: self.list), as: OrderedItemListView.self)
        recorder.waitForValues(count: 1)
        self.add(3)
        let latest = recorder.waitForValues(count: 2).last
        XCTAssertEqual((latest?.items ?? []).map { $0.id.makeData().first ?? 0 }, [3])
        redirection.dispose()
    }

    func testRemovingAndReplacingStayInTheSeparateList() {
        self.add(1)
        let redirection = self.redirect()
        self.add(4)
        self.fixture.transaction { transaction in
            transaction.removeOrderedItemListItem(collectionId: self.list, itemId: MemoryBuffer(data: Data([4])))
            transaction.replaceOrderedItemListItems(collectionId: self.list, items: [self.entry(5)])
        }
        XCTAssertEqual(self.items(), [5])
        redirection.dispose()
        self.fixture.transaction { _ in }
        XCTAssertEqual(self.items(), [1])
    }
}
