import XCTest
import UIKit
import SwiftSignalKit
@testable import Display

private final class OverlayStatusHost: StatusBarHost {
    let statusBarFrame = CGRect.zero
    let keyboardWindow: UIWindow? = nil
    let keyboardView: UIView? = nil
    let isApplicationInForeground = true
}

final class GlobalPresentationResetTests: XCTestCase {
    func testResetCancelsGlobalReadyViewBeforeItCanAttachAboveTheContainer() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 180))
        let context = preparedContext(parent)
        let old = ViewController(navigationBarPresentationData: nil)
        old.ready.set(.single(false))
        context.present(old)
        context.discardForAccessTransition()
        old.ready.set(.single(true))
        drain()
        XCTAssertTrue(context.controllers.isEmpty)
        XCTAssertNil(old.view.superview)
        withExtendedLifetime(parent) {}
    }

    func testGlobalDeliveryUsesCurrentAccessGuardAndOrdinaryPresentationStillWorks() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 180))
        let context = preparedContext(parent)
        let old = ViewController(navigationBarPresentationData: nil)
        old.ready.set(.single(false))
        var permitted = true
        context.presentationAllowed = { _ in permitted }
        context.present(old)
        permitted = false
        old.ready.set(.single(true))
        drain()
        XCTAssertTrue(context.controllers.isEmpty)
        XCTAssertNil(old.view.superview)
        permitted = true
        let current = ViewController(navigationBarPresentationData: nil)
        context.present(current)
        drain()
        XCTAssertEqual(context.controllers.count, 1)
        XCTAssertTrue(current.view.superview === parent)
        context.discardForAccessTransition()
        XCTAssertNil(current.view.superview)
        withExtendedLifetime(parent) {}
    }

    private func drain() {
        let delivered = expectation(description: "Global ready delivery")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 1)
    }

    private func preparedContext(_ view: UIView) -> GlobalOverlayPresentationContext {
        let context = GlobalOverlayPresentationContext(statusBarHost: OverlayStatusHost(), parentView: view)
        context.containerLayoutUpdated(ContainerViewLayout(size: view.bounds.size, metrics: LayoutMetrics(),
            deviceMetrics: DeviceMetrics(screenSize: view.bounds.size, scale: 1, statusBarHeight: 0, onScreenNavigationHeight: nil),
            intrinsicInsets: .zero, safeInsets: .zero, additionalInsets: .zero, statusBarHeight: nil, inputHeight: nil,
            inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false), transition: .immediate)
        return context
    }
}
