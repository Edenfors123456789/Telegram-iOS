import Foundation

/// Shared decision used by the native AppLock adapter. A Dual PIN authority cannot
/// be bypassed by a missing legacy challenge or a premature "root ready" callback.
public struct AccessLockPresentation {
    public let isLockable: Bool
    public let isLocked: Bool
    public let shouldCreatePIN: Bool
    public let shouldCover: Bool

    public init(legacyIsLockable: Bool, manuallyLocked: Bool, modeState: AccessPresentationState?,
                modeRootReady: Bool, coverHeld: Bool, applicationActive: Bool,
                rootPreparationInProgress: Bool = false) {
        isLockable = legacyIsLockable || modeState != nil
        if let modeState {
            let modeActive: Bool
            if case .active = modeState { modeActive = true } else { modeActive = false }
            isLocked = manuallyLocked || !modeActive || !modeRootReady || coverHeld || !applicationActive
        } else {
            isLocked = legacyIsLockable && manuallyLocked
        }
        let preparing: Bool
        switch modeState {
        case .preparing: preparing = true
        case .active: preparing = rootPreparationInProgress
        default: preparing = false
        }
        shouldCreatePIN = isLocked && !preparing
        shouldCover = !applicationActive || isLocked
    }
}
