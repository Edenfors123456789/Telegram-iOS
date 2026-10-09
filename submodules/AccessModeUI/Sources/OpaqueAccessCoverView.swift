import UIKit

/// No screenshot, wallpaper, theme, account or message is retained by this cover.
public final class OpaqueAccessCoverView: UIView {
    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .black
        self.isOpaque = true
        self.accessibilityElementsHidden = true
        self.isUserInteractionEnabled = true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
