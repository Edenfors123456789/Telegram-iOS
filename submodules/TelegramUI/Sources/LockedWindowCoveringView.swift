import Foundation
import UIKit
import Display
import TelegramPresentationData
import AsyncDisplayKit
import AccessModeUI

final class LockedWindowCoveringView: WindowCoveringView {
    private let contentView: OpaqueAccessCoverView
    
    init(theme: PresentationTheme) {
        self.contentView = OpaqueAccessCoverView(frame: .zero)
        
        super.init(frame: CGRect())
        
        self.backgroundColor = .black
        self.isOpaque = true
        self.addSubview(self.contentView)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateTheme(_ theme: PresentationTheme) {
        // The cover is independent of account/theme data.
    }
    
    override func updateLayout(_ size: CGSize) {
        self.contentView.frame = CGRect(origin: CGPoint(), size: size)
    }
}
