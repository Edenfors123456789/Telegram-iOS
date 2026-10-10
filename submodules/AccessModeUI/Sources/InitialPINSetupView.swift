import UIKit

/// Input composition only; record selection is not account authority. The native
/// caller must supply and revalidate its complete confirmed account snapshot.
public final class InitialPINSetupView: UIView {
    public struct AccountChoice {
        public let recordID: Int64
        public let title: String
        public init(recordID: Int64, title: String) { self.recordID = recordID; self.title = title }
    }
    public enum InputError: Error { case invalidAccounts }
    public var submitted: ((Int64, String?, String, String) -> Void)?
    public private(set) var selectedRecord: Int64?
    private let form: InitialPINSetupForm
    private let picker = UIButton(type: .system)
    private let label = UILabel()
    private let accounts: [AccountChoice]
    private let accountTitle: String
    private var finished = false

    public init(accountTitle: String, accounts: [AccountChoice], selectedRecord: Int64,
                strings: InitialPINSetupForm.Strings, requiresCurrentPasscode: Bool, currentUsesNumericKeyboard: Bool,
                background: UIColor, fieldBackground: UIColor, textColor: UIColor, accent: UIColor,
                initialFailure: Bool = false) throws {
        precondition(Thread.isMainThread)
        guard !accounts.isEmpty, Set(accounts.map(\.recordID)).count == accounts.count,
              accounts.contains(where: { $0.recordID == selectedRecord }) else { throw InputError.invalidAccounts }
        self.accounts = accounts; self.accountTitle = accountTitle; self.selectedRecord = selectedRecord
        form = InitialPINSetupForm(strings: strings, requiresCurrentPasscode: requiresCurrentPasscode,
            currentUsesNumericKeyboard: currentUsesNumericKeyboard, background: background,
            fieldBackground: fieldBackground, textColor: textColor, accent: accent, initialFailure: initialFailure)
        super.init(frame: .zero)
        backgroundColor = background
        label.text = accountTitle; label.textColor = textColor; label.font = .systemFont(ofSize: 13)
        picker.accessibilityIdentifier = "Passcode.Setup.Account"
        picker.contentHorizontalAlignment = .left; picker.titleLabel?.numberOfLines = 2
        picker.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        picker.tintColor = accent; picker.showsMenuAsPrimaryAction = true
        for view in [label, picker, form] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            picker.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            picker.leadingAnchor.constraint(equalTo: label.leadingAnchor), picker.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            picker.heightAnchor.constraint(equalToConstant: 48),
            form.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 8),
            form.leadingAnchor.constraint(equalTo: leadingAnchor), form.trailingAnchor.constraint(equalTo: trailingAnchor),
            form.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updatePicker()
        form.submitted = { [weak self] owner, a, b in
            guard let self, !self.finished, let record = self.selectedRecord else { return }
            let action = self.submitted
            self.invalidate()
            action?(record, owner, a, b)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationInactive),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @discardableResult public func selectRecord(_ recordID: Int64) -> Bool {
        precondition(Thread.isMainThread)
        guard !finished, accounts.contains(where: { $0.recordID == recordID }) else { return false }
        selectedRecord = recordID; updatePicker(); return true
    }
    private func updatePicker() {
        picker.setTitle(accounts.first(where: { $0.recordID == selectedRecord })?.title, for: .normal)
        picker.menu = UIMenu(title: accountTitle, children: accounts.map { account in
            UIAction(title: account.title, state: account.recordID == selectedRecord ? .on : .off) { [weak self] _ in
                self?.selectRecord(account.recordID)
            }
        })
    }
    public func invalidate() {
        precondition(Thread.isMainThread)
        finished = true; selectedRecord = nil; submitted = nil
        picker.menu = nil; picker.setTitle(nil, for: .normal); picker.setImage(nil, for: .normal); picker.isEnabled = false
        label.text = nil; form.invalidate(); isUserInteractionEnabled = false; endEditing(true)
    }
    @objc private func applicationInactive() { invalidate() }
    public override func willMove(toWindow newWindow: UIWindow?) {
        if window != nil && newWindow == nil { invalidate() }
        super.willMove(toWindow: newWindow)
    }
}
