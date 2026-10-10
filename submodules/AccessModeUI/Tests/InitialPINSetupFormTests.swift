import XCTest
import UIKit
import AccessModeUI

final class InitialPINSetupFormTests: XCTestCase {
    private func form(owner: Bool = false, numeric: Bool = true, failure: Bool = false) -> InitialPINSetupForm {
        InitialPINSetupForm(strings: .init(current: "Current passcode", first: "PIN A", firstConfirmation: "Repeat PIN A",
            second: "PIN B", secondConfirmation: "Repeat PIN B", submit: "Done", error: "Unable to update passcode"),
            requiresCurrentPasscode: owner, currentUsesNumericKeyboard: numeric,
            background: .white, fieldBackground: .white, textColor: .black, accent: .blue, initialFailure: failure)
    }
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func fields(_ form: InitialPINSetupForm) -> [UITextField] { descendants(form).compactMap { $0 as? UITextField } }
    private func field(_ id: String, in form: InitialPINSetupForm) throws -> UITextField {
        try XCTUnwrap(fields(form).first { $0.accessibilityIdentifier == "Passcode.Setup." + id })
    }
    private func button(_ form: InitialPINSetupForm) throws -> UIButton {
        try XCTUnwrap(descendants(form).first { $0.accessibilityIdentifier == "Passcode.Submit" } as? UIButton)
    }
    private func fill(_ form: InitialPINSetupForm) throws {
        for id in ["A", "AConfirm"] { try field(id, in: form).text = "123456" }
        for id in ["B", "BConfirm"] { try field(id, in: form).text = "654321" }
    }
    private func showsError(_ form: InitialPINSetupForm) -> Bool {
        descendants(form).compactMap { $0 as? UILabel }.contains { $0.text == "Unable to update passcode" }
    }
    private func assertCleared(_ form: InitialPINSetupForm, file: StaticString = #filePath, line: UInt = #line) {
        for field in fields(form) { XCTAssertEqual(field.text, "", file: file, line: line); XCTAssertFalse(field.isEnabled, file: file, line: line) }
        XCTAssertNil(form.submitted, file: file, line: line)
        XCTAssertFalse(form.isUserInteractionEnabled, file: file, line: line)
    }

    func testFreshSetupClearsAndSubmitsDistinctConfirmedPINsExactlyOnce() throws {
        let form = form(); try fill(form)
        XCTAssertEqual(fields(form).count, 4)
        var calls = 0
        form.submitted = { owner, a, b in
            calls += 1; XCTAssertNil(owner); XCTAssertEqual(a, "123456"); XCTAssertEqual(b, "654321")
            self.assertCleared(form)
            try? self.button(form).sendActions(for: .touchUpInside)
        }
        try button(form).sendActions(for: .touchUpInside)
        try button(form).sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 1); assertCleared(form)
    }

    func testFailedSetupShowsNeutralMessageWithEmptyFieldsAndRequiresFreshSubmission() throws {
        XCTAssertFalse(showsError(form()))
        let form = form(owner: true, failure: true)
        XCTAssertTrue(showsError(form))
        XCTAssertTrue(fields(form).allSatisfy { ($0.text ?? "").isEmpty && $0.isEnabled })
        var calls = 0
        form.submitted = { owner, a, b in
            calls += 1; XCTAssertEqual(owner, "123456"); XCTAssertEqual(a, "111111"); XCTAssertEqual(b, "222222")
            self.assertCleared(form); XCTAssertFalse(self.showsError(form))
        }
        try button(form).sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 0)
        try field("Current", in: form).text = "123456"
        for id in ["A", "AConfirm"] { try field(id, in: form).text = "111111" }
        for id in ["B", "BConfirm"] { try field(id, in: form).text = "222222" }
        try button(form).sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 1); assertCleared(form)
    }

    func testExistingFourDigitOrAlphanumericOwnerIsRequiredWithoutTreatingItAsANewSixDigitPIN() throws {
        for (old, numeric) in [("1234", true), ("Old secret passphrase", false)] {
            let form = form(owner: true, numeric: numeric); try fill(form)
            XCTAssertEqual(fields(form).count, 5)
            var calls = 0
            form.submitted = { owner, _, _ in calls += 1; XCTAssertEqual(owner, old); self.assertCleared(form) }
            try button(form).sendActions(for: .touchUpInside)
            XCTAssertEqual(calls, 0); XCTAssertTrue(showsError(form))
            try field("Current", in: form).text = old
            try button(form).sendActions(for: .touchUpInside)
            XCTAssertEqual(calls, 1)
        }
    }

    func testBothNewPINsRejectMalformedPasteMismatchesAndEqualityBeforeAdapter() throws {
        for id in ["A", "AConfirm", "B", "BConfirm"] {
            for value in ["12345", "1234567", "１２３４５６", "abcdef"] {
                let form = form(); try fill(form); try field(id, in: form).text = value
                form.submitted = { _, _, _ in XCTFail("Invalid new PIN reached adapter") }
                try button(form).sendActions(for: .touchUpInside)
                XCTAssertTrue(showsError(form))
            }
        }
        for id in ["AConfirm", "BConfirm"] {
            let form = form(); try fill(form); try field(id, in: form).text = "111111"
            form.submitted = { _, _, _ in XCTFail("Mismatched confirmation reached adapter") }
            try button(form).sendActions(for: .touchUpInside); XCTAssertTrue(showsError(form))
        }
        let form = form(); try fill(form)
        for id in ["B", "BConfirm"] { try field(id, in: form).text = "123456" }
        form.submitted = { _, _, _ in XCTFail("Identical PINs reached adapter") }
        try button(form).sendActions(for: .touchUpInside); XCTAssertTrue(showsError(form))
    }

    func testFieldsAreSecureAndDoNotAdvertiseAutofill() throws {
        for numeric in [true, false] {
            let form = form(owner: true, numeric: numeric)
            for field in fields(form) {
                XCTAssertTrue(field.isSecureTextEntry); XCTAssertNil(field.textContentType)
                XCTAssertEqual(field.keyboardType, field.accessibilityIdentifier == "Passcode.Setup.Current" && !numeric ? .default : .numberPad)
            }
        }
    }

    func testInactiveFormClearsSecretsAndCannotUseRetainedSubmission() throws {
        let form = form(owner: true); try fill(form); try field("Current", in: form).text = "1234"
        form.submitted = { _, _, _ in XCTFail("Inactive setup reached adapter") }
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        assertCleared(form); try button(form).sendActions(for: .touchUpInside)
    }

    func testRemovingAnAttachedSetupFormClearsAndDisablesIt() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        let root = UIViewController(); window.rootViewController = root; window.isHidden = false
        defer { window.isHidden = true }
        let form = form(owner: true); form.frame = root.view.bounds; root.view.addSubview(form)
        try fill(form); try field("Current", in: form).text = "1234"
        form.submitted = { _, _, _ in XCTFail("Detached setup reached adapter") }
        form.removeFromSuperview(); assertCleared(form)
        try button(form).sendActions(for: .touchUpInside)
    }
}
