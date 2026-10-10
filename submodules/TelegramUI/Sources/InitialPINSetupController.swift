import UIKit
import AsyncDisplayKit
import Display
import AccountContext
import TelegramPresentationData
import AccessModeCore
import AccessModeUI

/// Initial owner screen only. The factory must bind isCurrent to a complete
/// snapshot and cover/detach before dispatching authenticated setup. This input
/// controller has no authentication, credential-write or root authority.
final class InitialPINSetupController: ViewController {
    private let form: InitialPINSetupView
    private let isCurrent: () -> Bool

    init(context: AccountContext, accountTitle: String, accounts: [InitialPINSetupView.AccountChoice], selectedRecord: Int64,
         requiresCurrentPasscode: Bool, currentUsesNumericKeyboard: Bool,
         initialFailure: Bool = false, ownerPINCommitted: Bool = false,
         isCurrent: @escaping () -> Bool, submit: @escaping (Int64, String?, String, String) -> Void) throws {
        assert(Thread.isMainThread)
        guard isCurrent() else { throw AccessError.staleAuthorization }
        let data = context.sharedContext.currentPresentationData.with { $0 }
        let failureMessage = data.strings.PasscodeSettings_UpdateError + (ownerPINCommitted ?
            "\nPIN A уже сохранён. При повторной настройке используйте его как текущий код." : "")
        self.isCurrent = isCurrent
        self.form = try InitialPINSetupView(accountTitle: accountTitle, accounts: accounts, selectedRecord: selectedRecord,
            strings: .init(current: data.strings.EnterPasscode_EnterPasscode,
                first: "PIN A: " + data.strings.EnterPasscode_EnterNewPasscodeChange,
                firstConfirmation: "PIN A: " + data.strings.EnterPasscode_RepeatNewPasscode,
                second: "PIN B: " + data.strings.EnterPasscode_EnterNewPasscodeChange,
                secondConfirmation: "PIN B: " + data.strings.EnterPasscode_RepeatNewPasscode,
                submit: data.strings.Common_Done, error: failureMessage),
            requiresCurrentPasscode: requiresCurrentPasscode, currentUsesNumericKeyboard: currentUsesNumericKeyboard,
            background: data.theme.list.blocksBackgroundColor, fieldBackground: data.theme.list.itemBlocksBackgroundColor,
            textColor: data.theme.list.itemPrimaryTextColor, accent: data.theme.list.itemAccentColor,
            initialFailure: initialFailure)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: data, style: .glass))
        self.title = "Dual PIN"
        self.statusBar.statusBarStyle = data.theme.rootController.statusBarStyle.style
        self.form.submitted = { record, owner, a, b in
            guard isCurrent() else { return }
            submit(record, owner, a, b)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.form.invalidate() }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.form.backgroundColor
        self.displayNodeDidLoad()
        self.view.addSubview(self.form)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.form.frame = CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !self.isCurrent() { self.form.invalidate(); self.view.isHidden = true }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.form.invalidate()
    }
}
