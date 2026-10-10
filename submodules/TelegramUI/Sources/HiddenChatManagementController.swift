import UIKit
import AsyncDisplayKit
import Display
import AccountContext
import TelegramPresentationData
import AccessModeUI

/// A-only wrapper. The factory owns data filtering and exact ready-root actions.
final class HiddenChatManagementController: ViewController {
    private enum Failure: Error { case unavailable }
    private let management: HiddenChatManagementView
    private let isCurrent: () -> Bool

    init(context: AccountContext, items: [HiddenChatManagementView.Item], isCurrent: @escaping () -> Bool, select: @escaping (UUID) -> Void) throws {
        guard isCurrent() else { throw Failure.unavailable }
        let data = context.sharedContext.currentPresentationData.with { $0 }
        self.isCurrent = isCurrent
        self.management = try HiddenChatManagementView(items: items, searchPlaceholder: data.strings.Common_Search,
            emptyText: "Нет скрытых чатов", background: data.theme.list.blocksBackgroundColor,
            textColor: data.theme.list.itemPrimaryTextColor, accent: data.theme.list.itemAccentColor)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: data, style: .glass))
        self.title = "Скрытые чаты"
        self.statusBar.statusBarStyle = data.theme.rootController.statusBarStyle.style
        self.management.selected = { id in
            guard isCurrent() else { return }
            select(id)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.management.invalidate() }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.management.backgroundColor
        self.displayNodeDidLoad()
        guard self.isCurrent() else {
            self.management.invalidate()
            self.view.isHidden = true
            return
        }
        self.view.addSubview(self.management)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.management.frame = CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !self.isCurrent() { self.management.invalidate(); self.view.isHidden = true }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.management.invalidate()
    }
}
