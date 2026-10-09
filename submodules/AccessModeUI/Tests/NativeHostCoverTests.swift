import XCTest
import UIKit
@testable import Display
import AccessModeUI

final class NativeHostCoverTests: XCTestCase {
    func testActualTelegramNativeHostBlocksDelegatedTouchesAndKeepsCoverLastAfterResize() {
        let (window, host) = nativeWindowHostView()
        defer { window.isHidden = true }
        let button = UIButton(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        host.hitTest = { _, _ in button }
        XCTAssertTrue(window.hitTest(CGPoint(x: 1, y: 1), with: nil) === button)
        let protection = NativeSnapshotCover()
        let ticket = protection.show(on: window)
        XCTAssertNil(window.hitTest(CGPoint(x: 1, y: 1), with: nil))
        let nativeSibling = UIView(frame: window.bounds)
        nativeSibling.backgroundColor = .red
        window.addSubview(nativeSibling)
        XCTAssertTrue(window.subviews.last is OpaqueAccessCoverView)
        window.bounds = CGRect(x: 0, y: 0, width: 120, height: 80)
        window.setNeedsLayout()
        window.layoutIfNeeded()
        XCTAssertEqual(window.subviews.last?.frame, window.bounds)
        XCTAssertTrue(protection.hide(ticket))
        XCTAssertTrue(window.hitTest(CGPoint(x: 1, y: 1), with: nil) === button)
    }
}
