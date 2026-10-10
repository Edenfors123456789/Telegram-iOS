import Foundation

/// A particular freshly built root. It is deliberately not Codable or constructible
/// by clients. A matching PIN ticket alone does not prove that this root is ready.
public struct AccessRootPreparation: Equatable {
    fileprivate let owner: UUID
    fileprivate let generation: UUID
    public let account: AccountIdentity
    public let mode: AccessMode
    public let ticket: AccessTicket

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner && lhs.generation == rhs.generation
    }
}

/// Non-Codable menu action bound to one ready root. Display status is not authority.
public struct AccessChatVisibilityAction {
    fileprivate let preparation: AccessRootPreparation
    fileprivate let chat: ChatIdentity
    public let isHidden: Bool
}

/// A transient A-only load request bound to the exact ready root, never persisted.
public struct AccessHiddenChatManagementRequest {
    fileprivate let preparation: AccessRootPreparation
    public let chats: [ChatIdentity]
}

/// Main-thread adapter boundary: cover and detach first, validate async root delivery,
/// and publish/uncover only after matching account preparation. Native UI callbacks
/// must synchronously perform their named operation; no queued cover installation.
public final class AccessRootPresentation {
    private let coordinator: AccessModeCoordinator
    private let owner = UUID()
    private let isApplicationActive: () -> Bool
    private let authorizeRoot: (AccessModePolicy) throws -> Void
    private let showCover: () -> Void
    private let discardRoot: () -> Void
    private let publishReady: (AccessRootPreparation) -> Void
    private let hideCover: () throws -> Void
    private var preparing: AccessRootPreparation?
    private var active: AccessRootPreparation?
    private var pinChangeCoverEpoch: UUID?

    /// Presentation status only; data access still requires a fresh policy check.
    public var hasActiveRoot: Bool {
        precondition(Thread.isMainThread)
        return active != nil
    }

    public init(coordinator: AccessModeCoordinator, isApplicationActive: @escaping () -> Bool,
                authorizeRoot: @escaping (AccessModePolicy) throws -> Void = { _ in },
                showCover: @escaping () -> Void, discardRoot: @escaping () -> Void,
                publishReady: @escaping (AccessRootPreparation) -> Void, hideCover: @escaping () throws -> Void) throws {
        precondition(Thread.isMainThread)
        self.coordinator = coordinator
        self.isApplicationActive = isApplicationActive
        self.authorizeRoot = authorizeRoot
        self.showCover = showCover
        self.discardRoot = discardRoot
        self.publishReady = publishReady
        self.hideCover = hideCover
        showCover()
        discardRoot()
        try coordinator.lock()
    }

    public func lock() throws {
        precondition(Thread.isMainThread)
        preparing = nil
        active = nil
        pinChangeCoverEpoch = nil
        showCover()
        discardRoot()
        // Even if protected storage is unavailable, both local presentation layers
        // are already denied and the coordinator invalidates before attempting I/O.
        try coordinator.lock()
    }

    public func prepare(_ ticket: AccessTicket) throws -> AccessRootPreparation {
        precondition(Thread.isMainThread)
        let token = try coordinator.withPolicy(ticket, requireReady: false) { policy in
            guard coordinator.state == .preparing(policy.mode), isApplicationActive() else { throw AccessError.invalidTransition }
            return AccessRootPreparation(owner: owner, generation: UUID(), account: policy.selectedAccount,
                                         mode: policy.mode, ticket: ticket)
        }
        preparing = token
        pinChangeCoverEpoch = nil
        active = nil
        showCover()
        discardRoot()
        // A lifecycle event may reenter while root observers are being cleared.
        do { try withPreparingPolicy(token, authorizeRoot) }
        catch {
            if matches(token, preparing) { try? lock() }
            throw error
        }
        return token
    }

    public func withPreparingPolicy<T>(_ token: AccessRootPreparation, _ body: (AccessModePolicy) throws -> T) throws -> T {
        precondition(Thread.isMainThread)
        guard matches(token, preparing) else { throw AccessError.staleAuthorization }
        return try coordinator.withPolicy(token.ticket, requireReady: false) { policy in
            guard coordinator.state == .preparing(token.mode), policy.mode == token.mode,
                  policy.selectedAccount == token.account else { throw AccessError.staleAuthorization }
            return try body(policy)
        }
    }

    public func withActivePolicy<T>(_ body: (AccessModePolicy) throws -> T) throws -> T {
        precondition(Thread.isMainThread)
        guard let active else { throw AccessError.staleAuthorization }
        return try coordinator.withPolicy(active.ticket, body)
    }

    public func complete(_ token: AccessRootPreparation, preparedAccount: AccountIdentity) throws {
        precondition(Thread.isMainThread)
        try withPreparingPolicy(token) { _ in }
        guard preparedAccount == token.account, isApplicationActive() else {
            try lock()
            throw AccessError.invalidTransition
        }
        do {
            try withPreparingPolicy(token, authorizeRoot)
            try coordinator.completePreparation(token.ticket)
        }
        catch {
            // Only a current preparation reaches here; an old completion never
            // clears the root/cover of a newer mode.
            try? lock()
            throw error
        }
        preparing = nil
        active = token
        publishReady(token)
        // Publication can synchronously cause inactivity/lock; never uncover then.
        guard matches(token, active) else { throw AccessError.staleAuthorization }
        guard isApplicationActive() else {
            try lock()
            throw AccessError.invalidTransition
        }
        do { try coordinator.withPolicy(token.ticket, authorizeRoot) }
        catch {
            if matches(token, active) { try? lock() }
            throw error
        }
        do { try hideCover() }
        catch {
            if matches(token, active) { try? lock() }
            throw error
        }
    }

    public func cancel(_ token: AccessRootPreparation) throws {
        precondition(Thread.isMainThread)
        if matches(token, preparing) { try lock() }
    }

    public func selectAccount(_ account: AccountIdentity) throws -> AccessRootPreparation {
        try transition { old in
            try coordinator.selectAccount(account, ticket: old.ticket)
        } preflight: { policy in
            guard policy.allowsAccount(account) else { throw AccessError.authenticationRequired }
        }
    }

    public func setHidden(_ chat: ChatIdentity, hidden: Bool) throws -> AccessRootPreparation {
        try transition { old in
            try coordinator.setHidden(chat, hidden: hidden, ticket: old.ticket)
        } preflight: { policy in
            guard policy.canManageChatVisibility(chat) else { throw AccessError.authenticationRequired }
        }
    }

    public func makeChatVisibilityAction(_ chat: ChatIdentity) throws -> AccessChatVisibilityAction {
        precondition(Thread.isMainThread)
        guard coordinator.permitsChatManagement else { throw AccessError.authenticationRequired }
        guard let current = active else { throw AccessError.staleAuthorization }
        guard isApplicationActive() else { try lock(); throw AccessError.invalidTransition }
        let hidden = try withActivePolicy { policy -> Bool in
            guard policy.canManageChatVisibility(chat) else { throw AccessError.authenticationRequired }
            return policy.isMarkedHidden(chat)
        }
        return AccessChatVisibilityAction(preparation: current, chat: chat, isHidden: hidden)
    }

    public func makeHiddenChatManagementRequest() throws -> AccessHiddenChatManagementRequest {
        precondition(Thread.isMainThread)
        guard coordinator.permitsChatManagement else { throw AccessError.authenticationRequired }
        guard let current = active else { throw AccessError.staleAuthorization }
        guard isApplicationActive() else { try lock(); throw AccessError.invalidTransition }
        let chats = try withActivePolicy { policy -> [ChatIdentity] in
            guard policy.canManageHiddenChats else { throw AccessError.authenticationRequired }
            return policy.hiddenChatsForManagement
        }
        return AccessHiddenChatManagementRequest(preparation: current, chats: chats)
    }

    public func completeHiddenChatManagementRequest(_ request: AccessHiddenChatManagementRequest) throws -> [AccessChatVisibilityAction] {
        precondition(Thread.isMainThread)
        // A delayed/foreign result must never reset a newer root, even on the
        // same selected account. Check provenance before any lifecycle mutation.
        guard matches(request.preparation, active) else { throw AccessError.staleAuthorization }
        guard coordinator.permitsChatManagement else { throw AccessError.authenticationRequired }
        guard isApplicationActive() else { try lock(); throw AccessError.invalidTransition }
        return try withActivePolicy { policy in
            guard policy.canManageHiddenChats, policy.hiddenChatsForManagement == request.chats,
                  request.chats.allSatisfy({ policy.isMarkedHidden($0) }) else { throw AccessError.staleAuthorization }
            return request.chats.map { AccessChatVisibilityAction(preparation: request.preparation, chat: $0, isHidden: true) }
        }
    }

    public func performChatVisibilityAction(_ action: AccessChatVisibilityAction) throws -> AccessRootPreparation {
        precondition(Thread.isMainThread)
        // Refuse old/foreign menus before any cover, mutation or current-root reset.
        guard matches(action.preparation, active) else { throw AccessError.staleAuthorization }
        guard coordinator.permitsChatManagement else { throw AccessError.authenticationRequired }
        guard isApplicationActive() else { try lock(); throw AccessError.invalidTransition }
        try withActivePolicy { policy in
            guard policy.canManageChatVisibility(action.chat),
                  policy.isMarkedHidden(action.chat) == action.isHidden else { throw AccessError.staleAuthorization }
        }
        return try setHidden(action.chat, hidden: !action.isHidden)
    }

    public func preparePINChange() throws -> AccessPINChangeRequest {
        precondition(Thread.isMainThread)
        guard let old = active else { throw AccessError.staleAuthorization }
        try withActivePolicy { _ in
            guard coordinator.permitsPINManagement else { throw AccessError.authenticationRequired }
        }
        guard isApplicationActive() else { try lock(); throw AccessError.invalidTransition }
        let epoch = UUID()
        pinChangeCoverEpoch = epoch
        active = nil
        preparing = nil
        showCover()
        guard pinChangeCoverEpoch == epoch else { throw AccessError.staleAuthorization }
        discardRoot()
        guard pinChangeCoverEpoch == epoch else { throw AccessError.staleAuthorization }
        do {
            guard isApplicationActive() else { throw AccessError.invalidTransition }
            let request = try coordinator.preparePINChange(ticket: old.ticket)
            pinChangeCoverEpoch = nil
            return request
        } catch {
            if pinChangeCoverEpoch == epoch { try? lock() }
            throw error
        }
    }

    private func transition(_ mutation: (AccessRootPreparation) throws -> AccessTicket,
                            preflight: (AccessModePolicy) throws -> Void) throws -> AccessRootPreparation {
        precondition(Thread.isMainThread)
        guard let old = active else { throw AccessError.staleAuthorization }
        try withActivePolicy(preflight)
        active = nil
        preparing = nil
        showCover()
        discardRoot()
        do { return try prepare(mutation(old)) }
        catch {
            try? lock()
            throw error
        }
    }

    private func matches(_ lhs: AccessRootPreparation, _ rhs: AccessRootPreparation?) -> Bool {
        guard let rhs else { return false }
        return lhs.owner == owner && rhs.owner == owner && lhs.generation == rhs.generation
    }
}
