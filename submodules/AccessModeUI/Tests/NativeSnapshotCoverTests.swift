import XCTest
import UIKit
import AccessModeUI

final class NativeSnapshotCoverTests: XCTestCase {
    func window() throws -> SnapshotProtectedWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = SnapshotProtectedWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        window.backgroundColor = .red
        window.isHidden = false
        return window
    }

    func testNativeWindowRemainsOpaqueEvenWhenAnotherViewArrivesAfterCover() throws {
        let window = try window()
        defer { window.isHidden = true }
        let protection = NativeSnapshotCover()
        let ticket = protection.show(on: window)
        let laterNativeView = UIView(frame: window.bounds)
        laterNativeView.backgroundColor = .red
        window.addSubview(laterNativeView)
        let cover = try XCTUnwrap(window.subviews.last as? OpaqueAccessCoverView)
        window.bringSubviewToFront(laterNativeView)
        XCTAssertTrue(window.subviews.last === cover)
        window.sendSubviewToBack(cover)
        XCTAssertTrue(window.subviews.last === cover)
        window.exchangeSubview(at: 0, withSubviewAt: window.subviews.count - 1)
        XCTAssertTrue(window.subviews.last === cover)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let result = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { window.layer.render(in: $0.cgContext) }
        let bitmap = try XCTUnwrap(result.cgImage)
        let pixels = try XCTUnwrap(bitmap.dataProvider?.data) as Data
        for y in 0 ..< bitmap.height {
            for x in 0 ..< bitmap.width {
                let offset = y * bitmap.bytesPerRow + x * 4
                XCTAssertEqual(Array(pixels[offset ..< offset + 4]), [0, 0, 0, 255])
            }
        }
        XCTAssertTrue(window.accessibilityElementsHidden)
        XCTAssertFalse(window.isUserInteractionEnabled)
        XCTAssertNil(window.hitTest(CGPoint(x: 1, y: 1), with: nil))
        XCTAssertTrue(protection.hide(ticket))
        XCTAssertFalse(window.accessibilityElementsHidden)
        XCTAssertTrue(window.isUserInteractionEnabled)
    }

    func testOldForegroundCompletionCannotRemoveANewerCoverAndPreservesPriorWindowFlags() throws {
        let window = try window()
        defer { window.isHidden = true }
        window.accessibilityElementsHidden = true
        window.isUserInteractionEnabled = false
        let protection = NativeSnapshotCover()
        let old = protection.show(on: window)
        let current = protection.show(on: window)
        XCTAssertFalse(protection.isCurrent(old))
        XCTAssertTrue(protection.isCurrent(current))
        XCTAssertFalse(protection.hide(old))
        XCTAssertTrue(protection.isVisible)
        XCTAssertTrue(protection.hide(current))
        XCTAssertFalse(protection.isCurrent(current))
        XCTAssertFalse(protection.isVisible)
        XCTAssertTrue(window.accessibilityElementsHidden)
        XCTAssertFalse(window.isUserInteractionEnabled)
    }
}
