import XCTest
import UIKit
import AccessModeUI

final class InitialPINSetupViewTests: XCTestCase {
    private let choices: [InitialPINSetupView.AccountChoice] = [.init(recordID: -12, title: "Same name"), .init(recordID: 99, title: "Same name")]
    private func view(accounts: [InitialPINSetupView.AccountChoice]? = nil, selected: Int64 = -12) throws -> InitialPINSetupView {
        try InitialPINSetupView(accountTitle: "Shared account", accounts: accounts ?? choices, selectedRecord: selected,
            strings: .init(current: "Current passcode", first: "PIN A", firstConfirmation: "Repeat PIN A",
                second: "PIN B", secondConfirmation: "Repeat PIN B", submit: "Done", error: "Unable to update passcode"),
            requiresCurrentPasscode: true, currentUsesNumericKeyboard: true,
            background: .white, fieldBackground: .white, textColor: .black, accent: .blue)
    }
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func fill(_ view: InitialPINSetupView) throws {
        for field in descendants(view).compactMap({ $0 as? UITextField }) {
            switch field.accessibilityIdentifier {
            case "Passcode.Setup.Current": field.text = "1234"
            case "Passcode.Setup.A", "Passcode.Setup.AConfirm": field.text = "123456"
            default: field.text = "654321"
            }
        }
    }
    private func button(_ id: String, in view: InitialPINSetupView) throws -> UIButton {
        try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier == id } as? UIButton)
    }
    private func assertCleared(_ view: InitialPINSetupView, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(view.selectedRecord, file: file, line: line); XCTAssertNil(view.submitted, file: file, line: line)
        XCTAssertFalse(view.isUserInteractionEnabled, file: file, line: line)
        for field in descendants(view).compactMap({ $0 as? UITextField }) {
            XCTAssertEqual(field.text, "", file: file, line: line); XCTAssertFalse(field.isEnabled, file: file, line: line)
        }
        let picker = try button("Passcode.Setup.Account", in: view)
        XCTAssertNil(picker.menu, file: file, line: line); XCTAssertNil(picker.title(for: .normal), file: file, line: line)
        XCTAssertFalse(picker.isEnabled, file: file, line: line)
        XCTAssertFalse(view.selectRecord(99), file: file, line: line)
    }

    func testUnambiguousRecordSelectionClearsEntireCompositionBeforeSingleUseCallback() throws {
        for selected: Int64 in [-12, 99] {
            let view = try view(); try fill(view)
            XCTAssertTrue(view.selectRecord(selected)); XCTAssertEqual(view.selectedRecord, selected)
            let picker = try button("Passcode.Setup.Account", in: view)
            XCTAssertTrue(picker.showsMenuAsPrimaryAction); XCTAssertEqual(picker.menu?.children.count, 2)
            XCTAssertEqual(picker.menu?.title, "Shared account")
            var calls = 0
            view.submitted = { record, owner, a, b in
                calls += 1; XCTAssertEqual(record, selected); XCTAssertEqual(owner, "1234")
                XCTAssertEqual(a, "123456"); XCTAssertEqual(b, "654321")
                try? self.assertCleared(view)
                try? self.button("Passcode.Submit", in: view).sendActions(for: .touchUpInside)
            }
            try button("Passcode.Submit", in: view).sendActions(for: .touchUpInside)
            try button("Passcode.Submit", in: view).sendActions(for: .touchUpInside)
            XCTAssertEqual(calls, 1); try assertCleared(view)
        }
    }

    func testEmptyDuplicateAndUnlistedInitialChoicesAreRejected() throws {
        XCTAssertThrowsError(try view(accounts: []))
        XCTAssertThrowsError(try view(accounts: [.init(recordID: -12, title: "One"), .init(recordID: -12, title: "Another")]))
        XCTAssertThrowsError(try view(selected: 777))
        let view = try view(); XCTAssertFalse(view.selectRecord(777)); XCTAssertEqual(view.selectedRecord, -12)
    }

    func testInvalidPINDoesNotSubmitOrChangeSelectedAccount() throws {
        let view = try view(); try fill(view); XCTAssertTrue(view.selectRecord(99))
        let confirmation = try XCTUnwrap(descendants(view).compactMap { $0 as? UITextField }.first { $0.accessibilityIdentifier == "Passcode.Setup.BConfirm" })
        confirmation.text = "111111"
        view.submitted = { _, _, _, _ in XCTFail("Mismatched PIN reached setup adapter") }
        try button("Passcode.Submit", in: view).sendActions(for: .touchUpInside)
        XCTAssertEqual(view.selectedRecord, 99); XCTAssertNotNil(view.submitted)
        confirmation.text = "654321"
        var calls = 0; view.submitted = { record, _, _, _ in calls += 1; XCTAssertEqual(record, 99) }
        try button("Passcode.Submit", in: view).sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 1)
    }

    func testInactivityClearsPickerAndRetainedFormHandlers() throws {
        let view = try view(); try fill(view)
        view.submitted = { _, _, _, _ in XCTFail("Inactive composition reached adapter") }
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        try assertCleared(view)
        try button("Passcode.Submit", in: view).sendActions(for: .touchUpInside)
    }

    func testRemovingAnAttachedCompositionClearsSelectionAndCannotSubmit() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        let root = UIViewController(); window.rootViewController = root; window.isHidden = false
        defer { window.isHidden = true }
        let view = try view(); view.frame = root.view.bounds; root.view.addSubview(view); try fill(view)
        view.submitted = { _, _, _, _ in XCTFail("Detached composition reached adapter") }
        view.removeFromSuperview(); try assertCleared(view)
        try button("Passcode.Submit", in: view).sendActions(for: .touchUpInside)
    }
}
