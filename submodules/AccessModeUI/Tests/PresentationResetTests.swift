import XCTest
import UIKit
import SwiftSignalKit
@testable import Display

final class PresentationResetTests: XCTestCase {
    func testResetRemovesShownControllerAndRetainsOnlyExactLockController() {
        let context = PresentationContext()
        let old = ViewController(navigationBarPresentationData: nil)
        let lock = ViewController(navigationBarPresentationData: nil)
        context.present(old, on: .root, completion: {})
        context.present(lock, on: .root, completion: {})
        context.discardForAccessTransition(keeping: { $0 === lock })
        XCTAssertEqual(context.controllers.count, 1)
        XCTAssertTrue(context.controllers.first?.0 === lock)
    }

    func testLateReadyControllerCannotReappearAfterReset() {
        let context = preparedContext()
        let old = ViewController(navigationBarPresentationData: nil)
        old.ready.set(.single(false))
        var completed = false
        context.present(old, on: .root, blockInteraction: true, completion: { completed = true })
        context.discardForAccessTransition(keeping: { _ in false })
        old.ready.set(.single(true))
        let drained = expectation(description: "Ready delivery and teardown drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertTrue(context.controllers.isEmpty)
        XCTAssertNil(old.view.superview)
        XCTAssertFalse(completed, "A revoked presentation must not run its old completion")
    }

    func testRevokedPendingControllerCannotAppearAtReadinessTimeout() {
        let context = preparedContext()
        let old = ViewController(navigationBarPresentationData: nil)
        old.ready.set(.single(false))
        var completed = false
        context.present(old, on: .root, completion: { completed = true })
        context.discardForAccessTransition(keeping: { _ in false })
        let timeoutDrained = expectation(description: "Original two-second readiness timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { timeoutDrained.fulfill() }
        wait(for: [timeoutDrained], timeout: 3)
        XCTAssertTrue(context.controllers.isEmpty)
        XCTAssertNil(old.view.superview)
        XCTAssertFalse(completed)
    }

    func testPendingLockControllerSurvivesResetButOldPendingControllerDoesNot() {
        let context = preparedContext()
        let old = ViewController(navigationBarPresentationData: nil)
        let lock = ViewController(navigationBarPresentationData: nil)
        old.ready.set(.single(false))
        lock.ready.set(.single(false))
        context.present(old, on: .root, completion: {})
        context.present(lock, on: .root, completion: {})
        context.discardForAccessTransition(keeping: { $0 === lock })
        old.ready.set(.single(true))
        lock.ready.set(.single(true))
        let drained = expectation(description: "Allowed lock readiness")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(context.controllers.count, 1)
        XCTAssertTrue(context.controllers.first?.0 === lock)
        XCTAssertNil(old.view.superview)
        context.discardForAccessTransition(keeping: { _ in false })
        XCTAssertNil(lock.view.superview)
    }

    func testResetReenteredDuringReadyPublicationCannotAttachOldView() {
        let context = preparedContext()
        let old = ViewController(navigationBarPresentationData: nil)
        old.ready.set(.single(false))
        var completed = false
        context.controllersUpdated = { controllers in
            if !controllers.isEmpty { context.discardForAccessTransition(keeping: { _ in false }) }
        }
        defer { context.controllersUpdated = { _ in } }
        context.present(old, on: .root, completion: { completed = true })
        old.ready.set(.single(true))
        let drained = expectation(description: "Reentrant revocation")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertTrue(context.controllers.isEmpty)
        XCTAssertNil(old.view.superview)
        XCTAssertFalse(completed)
    }

    func testCurrentPresentationGuardDeniesQueuedReadinessAndItsCompletion() {
        let context = preparedContext()
        let old = ViewController(navigationBarPresentationData: nil)
        old.ready.set(.single(false))
        var permitted = true
        var completed = false
        context.presentationAllowed = { _ in permitted }
        context.present(old, on: .root, completion: { completed = true })
        permitted = false
        old.ready.set(.single(true))
        let drained = expectation(description: "Denied readiness")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertTrue(context.controllers.isEmpty)
        XCTAssertNil(old.view.superview)
        XCTAssertFalse(completed)
    }

    private func preparedContext() -> PresentationContext {
        let context = PresentationContext()
        context.view = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 180))
        context.containerLayoutUpdated(ContainerViewLayout(size: CGSize(width: 120, height: 180), metrics: LayoutMetrics(),
            deviceMetrics: DeviceMetrics(screenSize: CGSize(width: 120, height: 180), scale: 1, statusBarHeight: 0, onScreenNavigationHeight: nil),
            intrinsicInsets: .zero, safeInsets: .zero, additionalInsets: .zero, statusBarHeight: nil, inputHeight: nil,
            inputHeightIsInteractivellyChanging: false, inVoiceOver: false, presentedInFormSheet: false), transition: .immediate)
        return context
    }
}
