import UIKit

/// Native modal views are siblings of Telegram's container. Preserve the actual
/// subview order synchronously, including views added after the lifecycle cover.
open class SnapshotProtectedWindow: UIWindow {
    private var snapshotCover: UIView?
    public var isSnapshotProtected: Bool { snapshotCover != nil }

    open override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isSnapshotProtected else { return nil }
        return super.hitTest(point, with: event)
    }

    func setSnapshotCover(_ cover: UIView?) {
        assert(Thread.isMainThread)
        snapshotCover?.removeFromSuperview()
        snapshotCover = cover
        if let cover { addSubview(cover) }
    }

    open override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        if let cover = snapshotCover, subview !== cover { bringSubviewToFront(cover) }
    }

    open override func bringSubviewToFront(_ view: UIView) {
        super.bringSubviewToFront(view)
        restoreCoverOrder()
    }

    open override func sendSubviewToBack(_ view: UIView) {
        super.sendSubviewToBack(view)
        restoreCoverOrder()
    }

    open override func exchangeSubview(at index1: Int, withSubviewAt index2: Int) {
        super.exchangeSubview(at: index1, withSubviewAt: index2)
        restoreCoverOrder()
    }

    private func restoreCoverOrder() {
        if let cover = snapshotCover { super.bringSubviewToFront(cover) }
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        if let cover = snapshotCover {
            cover.frame = bounds
            bringSubviewToFront(cover)
        }
    }
}
