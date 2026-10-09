import XCTest
@testable import AccessModeCore

final class LockPresentationTests: XCTestCase {
    func decision(_ mode: AccessPresentationState?, legacy: Bool = false, manual: Bool = false,
                  ready: Bool = false, held: Bool = false, active: Bool = true) -> AccessLockPresentation {
        AccessLockPresentation(legacyIsLockable: legacy, manuallyLocked: manual,
            modeState: mode, modeRootReady: ready, coverHeld: held, applicationActive: active)
    }

    func testConfiguredVaultCannotUseMissingLegacyChallengeAsAnUnlock() {
        let value = decision(.locked, ready: true)
        XCTAssertTrue(value.isLockable)
        XCTAssertTrue(value.isLocked)
        XCTAssertTrue(value.shouldCreatePIN)
        XCTAssertTrue(value.shouldCover)
    }

    func testPreparationKeepsCoverWithoutCreatingAnotherPINPrompt() {
        for mode in AccessMode.allCases {
            for ready in [false, true] {
                let value = decision(.preparing(mode), ready: ready)
                XCTAssertTrue(value.isLocked)
                XCTAssertTrue(value.shouldCover)
                XCTAssertFalse(value.shouldCreatePIN)
            }
        }
        let beforeMutation = AccessLockPresentation(legacyIsLockable: true, manuallyLocked: false,
            modeState: .active(.a), modeRootReady: false, coverHeld: true, applicationActive: true,
            rootPreparationInProgress: true)
        XCTAssertTrue(beforeMutation.shouldCover)
        XCTAssertFalse(beforeMutation.shouldCreatePIN)
        let actualLock = AccessLockPresentation(legacyIsLockable: false, manuallyLocked: true,
            modeState: .locked, modeRootReady: false, coverHeld: true, applicationActive: true,
            rootPreparationInProgress: true)
        XCTAssertTrue(actualLock.shouldCreatePIN)
    }

    func testActiveRoleStillRequiresMatchingRootReleasedBarrierAndActiveApplication() {
        for mode in AccessMode.allCases {
            for input in [(false, false, true, false), (true, true, true, false),
                          (true, false, false, false), (true, false, true, true)] {
                let value = decision(.active(mode), manual: input.3, ready: input.0, held: input.1, active: input.2)
                XCTAssertTrue(value.isLocked)
                XCTAssertTrue(value.shouldCover)
            }
            let value = decision(.active(mode), ready: true)
            XCTAssertFalse(value.isLocked)
            XCTAssertFalse(value.shouldCover)
        }
    }

    func testOrdinaryUnconfiguredOnboardingAndLegacyPINRetainTheirBehavior() {
        XCTAssertFalse(decision(nil, manual: true, held: true).isLockable)
        XCTAssertFalse(decision(nil, manual: true, held: true).isLocked)
        XCTAssertTrue(decision(nil, active: false).shouldCover)
        XCTAssertTrue(decision(nil, legacy: true, manual: true).shouldCreatePIN)
        XCTAssertFalse(decision(nil, legacy: true, ready: false).shouldCover)
    }
}
