import XCTest
import UIKit
import AccessModeUI

final class HiddenChatManagementViewTests: XCTestCase {
    private let first = UUID(), second = UUID(), third = UUID()
    private func view(items: [HiddenChatManagementView.Item]? = nil) throws -> HiddenChatManagementView {
        try HiddenChatManagementView(items: items ?? [.init(id: first, title: "Alpha"), .init(id: second, title: "Alpha"), .init(id: third, title: "Béta")],
            searchPlaceholder: "Search hidden chats", emptyText: "No hidden chats", background: .white, textColor: .black, accent: .blue)
    }
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func table(_ view: UIView) throws -> UITableView { try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier == "HiddenChats.List" } as? UITableView) }
    private func search(_ view: UIView) throws -> UITextField { try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier == "HiddenChats.Search" } as? UITextField) }
    private func cleared(_ view: HiddenChatManagementView, cell: UITableViewCell? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(view.visibleIdentifiers.isEmpty, file: file, line: line)
        XCTAssertNil(view.selected, file: file, line: line)
        XCTAssertFalse(view.isUserInteractionEnabled, file: file, line: line)
        XCTAssertEqual(try search(view).text, "", file: file, line: line)
        XCTAssertNil(try search(view).placeholder, file: file, line: line)
        XCTAssertFalse(try search(view).isEnabled, file: file, line: line)
        XCTAssertNil(try table(view).dataSource, file: file, line: line)
        XCTAssertNil(try table(view).delegate, file: file, line: line)
        if let cell { XCTAssertNil(cell.textLabel?.text, file: file, line: line); XCTAssertNil(cell.accessibilityLabel, file: file, line: line) }
        XCTAssertFalse(view.selectItem(first), file: file, line: line)
    }

    func testEqualTitlesSelectTheExactIDAndClearBeforeSingleUseCallback() throws {
        let view = try view(), table = try table(view)
        let cell = try XCTUnwrap(table.dataSource).tableView(table, cellForRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(cell.textLabel?.text, "Alpha")
        var calls = 0
        view.selected = { id in calls += 1; XCTAssertEqual(id, self.second); try? self.cleared(view, cell: cell); XCTAssertFalse(view.selectItem(self.first)) }
        XCTAssertTrue(view.selectItem(second)); XCTAssertEqual(calls, 1)
        XCTAssertFalse(view.selectItem(second)); try cleared(view, cell: cell)
    }

    func testSearchUsesVisibleIDsAndRejectsFilteredOrUnknownSelection() throws {
        let view = try view(), search = try search(view)
        XCTAssertNil(search.textContentType); XCTAssertEqual(search.autocorrectionType, .no); XCTAssertEqual(search.spellCheckingType, .no)
        view.selected = { _ in XCTFail("Filtered/unknown row reached adapter") }
        view.updateSearch("ALPHA"); XCTAssertEqual(view.visibleIdentifiers, [first, second])
        XCTAssertFalse(view.selectItem(third)); XCTAssertFalse(view.selectItem(UUID()))
        XCTAssertNotNil(view.selected); XCTAssertTrue(view.isUserInteractionEnabled)
        view.updateSearch("beta"); XCTAssertEqual(view.visibleIdentifiers, [third])
        view.updateSearch(""); XCTAssertEqual(view.visibleIdentifiers, [first, second, third])
    }

    func testDuplicateIDsRefuseButAnEmptyManagementListIsValid() throws {
        XCTAssertThrowsError(try view(items: [.init(id: first, title: "One"), .init(id: first, title: "Another")]))
        let empty = try view(items: [])
        XCTAssertTrue(empty.visibleIdentifiers.isEmpty); XCTAssertFalse(empty.selectItem(first))
    }

    func testInvalidationClearsEvenRetainedCellDataAndCannotRestoreBySearch() throws {
        let view = try view(), table = try table(view)
        let cell = try XCTUnwrap(table.dataSource).tableView(table, cellForRowAt: IndexPath(row: 2, section: 0))
        view.updateSearch("Private search"); view.selected = { _ in XCTFail("Invalidated view reached adapter") }
        view.invalidate(); try cleared(view, cell: cell)
        view.updateSearch("Alpha"); view.selected = { _ in XCTFail("Late handler reopened invalidated view") }; try cleared(view, cell: cell)
    }

    func testInactivityClearsNamesQueryAndHandlers() throws {
        let view = try view(), table = try table(view)
        let cell = try XCTUnwrap(table.dataSource).tableView(table, cellForRowAt: IndexPath(row: 0, section: 0))
        view.updateSearch("Alpha"); view.selected = { _ in XCTFail("Inactive view reached adapter") }
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        try cleared(view, cell: cell)
    }

    func testAttachedWindowRemovalClearsManagementAndCannotSelect() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        let root = UIViewController(); window.rootViewController = root; window.isHidden = false
        defer { window.isHidden = true }
        let view = try view(); view.frame = root.view.bounds; root.view.addSubview(view)
        view.updateSearch("Alpha"); view.selected = { _ in XCTFail("Removed view reached adapter") }
        view.removeFromSuperview(); try cleared(view)
    }

    func testWindowLayoutRendersSearchAndTheRealTableRows() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        let root = UIViewController(); window.rootViewController = root; window.isHidden = false
        defer { window.isHidden = true }
        let view = try view(); view.frame = root.view.bounds; root.view.addSubview(view)
        view.layoutIfNeeded()
        let table = try table(view); table.reloadData(); table.layoutIfNeeded()
        XCTAssertGreaterThan(try search(view).frame.width, 200)
        XCTAssertGreaterThan(table.frame.height, 200)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 3)
        XCTAssertEqual(table.visibleCells.compactMap { $0.textLabel?.text }, ["Alpha", "Alpha", "Béta"])
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image); attachment.name = "hidden-chat-management-layout"; attachment.lifetime = .keepAlways
        add(attachment)
        view.removeFromSuperview(); try cleared(view)
    }
}
