import UIKit

/// Input only. The main-app adapter must verify the legacy owner and commit a
/// covered initial setup request; this view never issues an access grant.
public final class InitialPINSetupForm: UIView {
    public struct Strings {
        public let current, first, firstConfirmation, second, secondConfirmation, submit, error: String
        public init(current: String, first: String, firstConfirmation: String, second: String,
                    secondConfirmation: String, submit: String, error: String) {
            self.current = current; self.first = first; self.firstConfirmation = firstConfirmation
            self.second = second; self.secondConfirmation = secondConfirmation
            self.submit = submit; self.error = error
        }
    }
    public var submitted: ((String?, String, String) -> Void)?
    private let fields: [UITextField]
    private let submitButton: UIButton
    private let errorLabel: UILabel
    private let strings: Strings
    private let requiresCurrentPasscode: Bool
    private var finished = false

    public init(strings: Strings, requiresCurrentPasscode: Bool, currentUsesNumericKeyboard: Bool,
                background: UIColor, fieldBackground: UIColor, textColor: UIColor, accent: UIColor) {
        self.strings = strings; self.requiresCurrentPasscode = requiresCurrentPasscode
        fields = (0 ..< (requiresCurrentPasscode ? 5 : 4)).map { _ in UITextField() }
        submitButton = UIButton(type: .system); errorLabel = UILabel()
        super.init(frame: .zero)
        backgroundColor = background
        let names = (requiresCurrentPasscode ? ["Current"] : []) + ["A", "AConfirm", "B", "BConfirm"]
        let placeholders = (requiresCurrentPasscode ? [strings.current] : []) + [strings.first, strings.firstConfirmation, strings.second, strings.secondConfirmation]
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        addSubview(scroll); scroll.addSubview(stack)
        for (index, field) in fields.enumerated() {
            field.accessibilityIdentifier = "Passcode.Setup." + names[index]
            field.placeholder = placeholders[index]
            field.isSecureTextEntry = true
            field.keyboardType = names[index] == "Current" && !currentUsesNumericKeyboard ? .default : .numberPad
            field.textContentType = nil; field.autocorrectionType = .no; field.spellCheckingType = .no
            field.inputAssistantItem.leadingBarButtonGroups = []; field.inputAssistantItem.trailingBarButtonGroups = []
            field.backgroundColor = fieldBackground; field.textColor = textColor
            field.borderStyle = .roundedRect; field.font = .systemFont(ofSize: 17)
            field.heightAnchor.constraint(equalToConstant: 48).isActive = true
            stack.addArrangedSubview(field)
        }
        errorLabel.textColor = textColor; errorLabel.numberOfLines = 0; errorLabel.font = .systemFont(ofSize: 15)
        stack.addArrangedSubview(errorLabel)
        submitButton.setTitle(strings.submit, for: .normal); submitButton.tintColor = accent
        submitButton.accessibilityIdentifier = "Passcode.Submit"
        submitButton.addTarget(self, action: #selector(submitPressed), for: .touchUpInside)
        submitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        stack.addArrangedSubview(submitButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applicationInactive),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public func invalidate() {
        precondition(Thread.isMainThread)
        finished = true; submitted = nil
        fields.forEach { $0.text = ""; $0.isEnabled = false }
        errorLabel.text = nil; submitButton.isEnabled = false
        isUserInteractionEnabled = false; endEditing(true)
    }
    @objc private func applicationInactive() { invalidate() }
    public override func willMove(toWindow newWindow: UIWindow?) {
        if window != nil && newWindow == nil { invalidate() }
        super.willMove(toWindow: newWindow)
    }
    @objc private func submitPressed() {
        guard !finished else { return }
        let values = fields.map { $0.text ?? "" }
        let pins = Array(values.dropFirst(requiresCurrentPasscode ? 1 : 0))
        guard (!requiresCurrentPasscode || !values[0].isEmpty),
              pins.allSatisfy({ $0.utf8.count == 6 && $0.utf8.allSatisfy({ (48 ... 57).contains($0) }) }),
              pins[0] == pins[1], pins[2] == pins[3], pins[0] != pins[2] else {
            errorLabel.text = strings.error
            return
        }
        let action = submitted
        let owner = requiresCurrentPasscode ? values[0] : nil
        invalidate()
        action?(owner, pins[0], pins[2])
    }
}
