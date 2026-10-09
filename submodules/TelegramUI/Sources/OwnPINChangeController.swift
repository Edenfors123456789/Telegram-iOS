import UIKit
import AsyncDisplayKit
import Display
import AccountContext
import TelegramPresentationData
import AccessModeUI

/// Generic own-passcode settings. No role name or other credential is exposed.
final class OwnPINChangeController: ViewController {
    private let form: OwnPINChangeForm
    private let isCurrent: () -> Bool

    init(context: AccountContext, isCurrent: @escaping () -> Bool, submit: @escaping (String, String) -> Void) {
        let data = context.sharedContext.currentPresentationData.with { $0 }
        self.isCurrent = isCurrent
        self.form = OwnPINChangeForm(strings: .init(current: data.strings.EnterPasscode_EnterPasscode,
            replacement: data.strings.EnterPasscode_EnterNewPasscodeChange,
            confirmation: data.strings.EnterPasscode_RepeatNewPasscode,
            submit: data.strings.Common_Done, error: data.strings.PasscodeSettings_UpdateError),
            background: data.theme.list.blocksBackgroundColor, fieldBackground: data.theme.list.itemBlocksBackgroundColor,
            textColor: data.theme.list.itemPrimaryTextColor, accent: data.theme.list.itemAccentColor)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: data, style: .glass))
        self.title = data.strings.PasscodeSettings_ChangePasscode
        self.statusBar.statusBarStyle = data.theme.rootController.statusBarStyle.style
        self.form.submitted = { current, replacement in
            guard isCurrent() else { return }
            submit(current, replacement)
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
