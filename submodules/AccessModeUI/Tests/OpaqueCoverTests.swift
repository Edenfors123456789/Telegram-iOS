import XCTest
import UIKit
import AccessModeUI

final class OpaqueCoverTests: XCTestCase {
    func testRenderedCoverContainsNoUnderlyingPixels() throws {
        let underlay = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        underlay.backgroundColor = .red
        let cover = OpaqueAccessCoverView(frame: underlay.bounds)
        underlay.addSubview(cover)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: underlay.bounds.size, format: format).image { context in
            underlay.layer.render(in: context.cgContext)
        }
        let bitmap = try XCTUnwrap(image.cgImage)
        let data = try XCTUnwrap(bitmap.dataProvider?.data) as Data
        XCTAssertEqual(bitmap.bitsPerPixel, 32)
        for y in 0 ..< bitmap.height {
            for x in 0 ..< bitmap.width {
                let offset = y * bitmap.bytesPerRow + x * 4
                XCTAssertEqual(Array(data[offset ..< offset + 4]), [0, 0, 0, 255], "Cover must contain only opaque neutral pixels")
            }
        }
        XCTAssertTrue(cover.isOpaque)
    }

    func testCoverBlocksTouchesAndHidesAccessibilityContent() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let underlay = UIView(frame: frame)
        let button = UIButton(frame: frame)
        underlay.addSubview(button)
        let cover = OpaqueAccessCoverView(frame: frame)
        underlay.addSubview(cover)
        XCTAssertTrue(underlay.hitTest(CGPoint(x: 50, y: 50), with: nil) === cover)
        XCTAssertTrue(cover.accessibilityElementsHidden)
        XCTAssertTrue(cover.subviews.isEmpty)
    }
}
