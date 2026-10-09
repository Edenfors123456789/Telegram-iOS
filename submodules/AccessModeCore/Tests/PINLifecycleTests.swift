import XCTest
import AccessModeCore

final class PINLifecycleTests: XCTestCase {
    func testInactivityAloneRevokesVerificationBeforeBackground() {
        var state = PINEntryLifecycle(isMainApp: true)
        XCTAssertFalse(state.canAuthenticate)
        state.updateApplicationInForeground(true)
        state.updateApplicationIsActive(true)
        XCTAssertTrue(state.canAuthenticate)
        let inputGeneration = state.generation
        state.updateApplicationIsActive(false)
        XCTAssertFalse(state.canAuthenticate)
        XCTAssertFalse(state.acceptsResult(generation: inputGeneration))
        state.updateApplicationIsActive(true)
        XCTAssertTrue(state.canAuthenticate)
        XCTAssertFalse(state.acceptsResult(generation: inputGeneration))
    }

    func testSynchronousLockInvalidationDoesNotDependOnQueuedLifecycleSignals() {
        var state = PINEntryLifecycle(isMainApp: true)
        state.updateApplicationInForeground(true)
        state.updateApplicationIsActive(true)
        let old = state.generation
        state.invalidatePendingResult()
        XCTAssertFalse(state.acceptsResult(generation: old))
        XCTAssertTrue(state.canAuthenticate)
        state.dismiss()
        state.updateApplicationIsActive(true)
        state.updateApplicationInForeground(true)
        XCTAssertFalse(state.canAuthenticate)
    }
}
