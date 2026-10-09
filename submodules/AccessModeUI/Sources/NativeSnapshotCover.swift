import UIKit

public struct NativeSnapshotTicket {
    let owner: UUID
    let generation: UUID
}

/// Covers the application's UIWindow, including native modal siblings above the
/// Telegram container. Main-thread only. Hide only after the internal lock cover is
/// installed and old native modals are gone; it does not authenticate/unlock UI.
public final class NativeSnapshotCover {
    private final class Entry {
        weak var window: SnapshotProtectedWindow?
        let cover: OpaqueAccessCoverView
        let accessibilityHidden: Bool
        let interactionEnabled: Bool

        init(window: SnapshotProtectedWindow) {
            self.window = window
            self.cover = OpaqueAccessCoverView(frame: window.bounds)
            self.cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.accessibilityHidden = window.accessibilityElementsHidden
            self.interactionEnabled = window.isUserInteractionEnabled
        }
    }

    private let owner = UUID()
    private var generation = UUID()
    private var entries: [ObjectIdentifier: Entry] = [:]

    public init() {}
    public var isVisible: Bool { !entries.isEmpty }

    @discardableResult public func show(on window: SnapshotProtectedWindow) -> NativeSnapshotTicket {
        assert(Thread.isMainThread)
        generation = UUID()
        let key = ObjectIdentifier(window)
        let entry = entries[key] ?? Entry(window: window)
        entries[key] = entry
        window.accessibilityElementsHidden = true
        window.isUserInteractionEnabled = false
        entry.cover.frame = window.bounds
        window.setSnapshotCover(entry.cover)
        window.layoutIfNeeded()
        CATransaction.flush()
        return NativeSnapshotTicket(owner: owner, generation: generation)
    }

    /// An old dismissal/foreground callback is harmless, even after a new resign.
    @discardableResult public func hide(_ ticket: NativeSnapshotTicket) -> Bool {
        assert(Thread.isMainThread)
        guard ticket.owner == owner, ticket.generation == generation else { return false }
        generation = UUID()
        for entry in entries.values {
            entry.window?.setSnapshotCover(nil)
            entry.window?.accessibilityElementsHidden = entry.accessibilityHidden
            entry.window?.isUserInteractionEnabled = entry.interactionEnabled
        }
        entries.removeAll()
        return true
    }
}
