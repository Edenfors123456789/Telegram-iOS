import Foundation

/// Main-app PIN work is unavailable before both lifecycle signals are active.
/// The extension adapter must supply its own dismissal/revocation lifecycle.
public struct PINEntryLifecycle {
    private let isMainApp: Bool
    private var foreground: Bool
    private var active: Bool
    private var dismissed = false
    public private(set) var generation: UInt64 = 0

    public init(isMainApp: Bool) {
        self.isMainApp = isMainApp
        self.foreground = !isMainApp
        self.active = !isMainApp
    }

    public var canAuthenticate: Bool { !dismissed && foreground && active }

    @discardableResult public mutating func updateApplicationInForeground(_ value: Bool) -> Bool {
        guard isMainApp, foreground != value else { return false }
        foreground = value
        if !value { invalidatePendingResult(); return true }
        return false
    }

    @discardableResult public mutating func updateApplicationIsActive(_ value: Bool) -> Bool {
        guard isMainApp, active != value else { return false }
        active = value
        if !value { invalidatePendingResult(); return true }
        return false
    }

    public mutating func invalidatePendingResult() { generation &+= 1 }
    public func acceptsResult(generation: UInt64) -> Bool { canAuthenticate && self.generation == generation }

    public mutating func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        invalidatePendingResult()
    }
}
