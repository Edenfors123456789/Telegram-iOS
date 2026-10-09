import XCTest
import UIKit
import AccessModeUI

final class OwnPINChangeFormTests: XCTestCase {
    private func form() -> OwnPINChangeForm {
        OwnPINChangeForm(strings: .init(current: "Current passcode", replacement: "New passcode", confirmation: "Repeat passcode", submit: "Done", error: "Unable to update passcode"),
            background: .white, fieldBackground: .white, textColor: .black, accent: .blue)
    }
    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func field(_ id: String, in form: OwnPINChangeForm) throws -> UITextField {
        try XCTUnwrap(descendants(form).first { $0.accessibilityIdentifier == id } as? UITextField)
    }
    private func button(_ form: OwnPINChangeForm) throws -> UIButton {
        try XCTUnwrap(descendants(form).first { $0.accessibilityIdentifier == "Passcode.Submit" } as? UIButton)
    }
    private func fill(_ form: OwnPINChangeForm, current: String = "123456", replacement: String = "222222", confirmation: String = "222222") throws {
        try field("Passcode.Current", in: form).text = current
        try field("Passcode.New", in: form).text = replacement
        try field("Passcode.Confirm", in: form).text = confirmation
    }

    func testSubmissionClearsAllPINFieldsBeforeCallingAdapterAndCannotRepeat() throws {
        let form = form()
        try fill(form)
        var calls = 0
        form.submitted = { current, replacement in
            calls += 1
            XCTAssertEqual(current, "123456"); XCTAssertEqual(replacement, "222222")
            for field in self.descendants(form).compactMap({ $0 as? UITextField }) { XCTAssertEqual(field.text, "") }
            XCTAssertFalse(form.isUserInteractionEnabled)
            try? self.button(form).sendActions(for: .touchUpInside)
        }
        try button(form).sendActions(for: .touchUpInside)
        try button(form).sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(form.submitted)
    }

    func testMalformedPastedPINOrMismatchedConfirmationCannotReachAdapter() throws {
        for candidate in ["1234", "1234567", "１２３４５６", "12345a", ""] {
            let form = form(); try fill(form, current: candidate)
            form.submitted = { _, _ in XCTFail("Invalid current PIN reached adapter") }
            try button(form).sendActions(for: .touchUpInside)
            XCTAssertTrue(descendants(form).compactMap { $0 as? UILabel }.contains { $0.text == "Unable to update passcode" })
        }
        let form = form(); try fill(form, confirmation: "111111")
        form.submitted = { _, _ in XCTFail("Mismatched confirmation reached adapter") }
        try button(form).sendActions(for: .touchUpInside)
        XCTAssertTrue(descendants(form).compactMap { $0 as? UILabel }.contains { $0.text == "Unable to update passcode" })
        for candidate in ["00000", "0000000", "١٢٣٤٥٦", "ABCDEF"] {
            let form = self.form(); try fill(form, replacement: candidate, confirmation: candidate)
            form.submitted = { _, _ in XCTFail("Invalid new PIN reached adapter") }
            try button(form).sendActions(for: .touchUpInside)
            XCTAssertTrue(descendants(form).compactMap { $0 as? UILabel }.contains { $0.text == "Unable to update passcode" })
        }
    }

    func testInvalidationClearsSecretsAndDisablesDetachedForm() throws {
        let form = form(); try fill(form)
        form.submitted = { _, _ in XCTFail("Detached form executed") }
        form.invalidate()
        for field in descendants(form).compactMap({ $0 as? UITextField }) { XCTAssertEqual(field.text, "") }
        XCTAssertFalse(form.isUserInteractionEnabled); XCTAssertNil(form.submitted)
        try button(form).sendActions(for: .touchUpInside)
    }

    func testInactiveNotificationClearsSecretsWithoutSubmittingOrRetainingCallback() throws {
        let form = form(); try fill(form)
        form.submitted = { _, _ in XCTFail("Background form executed") }
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        for field in descendants(form).compactMap({ $0 as? UITextField }) { XCTAssertEqual(field.text, "") }
        XCTAssertFalse(form.isUserInteractionEnabled); XCTAssertNil(form.submitted)
        try button(form).sendActions(for: .touchUpInside)
    }

    func testRemovingAnAttachedFormClearsItsPINsAndRefusesOldCallbacks() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        let root = UIViewController(); window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let form = form(); form.frame = root.view.bounds
        root.view.addSubview(form)
        try fill(form)
        form.submitted = { _, _ in XCTFail("Removed form executed") }
        form.removeFromSuperview()
        for field in descendants(form).compactMap({ $0 as? UITextField }) { XCTAssertEqual(field.text, "") }
        XCTAssertNil(form.submitted); XCTAssertFalse(form.isUserInteractionEnabled)
        try button(form).sendActions(for: .touchUpInside)
    }

    func testInputDoesNotAdvertiseAutofillAndInvalidEntryCanBeCorrectedBeforeSubmission() throws {
        let form = form()
        for field in descendants(form).compactMap({ $0 as? UITextField }) {
            XCTAssertTrue(field.isSecureTextEntry); XCTAssertNil(field.textContentType)
            XCTAssertEqual(field.keyboardType, .numberPad)
        }
        var calls = 0; form.submitted = { _, _ in calls += 1 }
        try fill(form, confirmation: "111111"); try button(form).sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 0)
        try fill(form); try button(form).sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 1)
    }
}
