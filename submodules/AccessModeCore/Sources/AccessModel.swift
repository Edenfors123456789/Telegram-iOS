import Foundation

public enum AccessMode: String, Codable, CaseIterable, Sendable { case a, b }
public enum AccountEnvironment: String, Codable, Sendable { case production, test }
public enum AccountOwnership: String, Codable, Sendable { case shared, a, b }

public enum AccessError: Error, Equatable {
    case unavailable, corrupt, unsupportedVersion, invalidConfiguration
    case invalidPIN, identicalPINs, cooldown, authenticationRequired, staleAuthorization
    case alreadyConfigured, missingKey, revisionConflict, invalidTransition
    case keychain(Int32)
}

public struct AccountIdentity: Codable, Hashable, Sendable {
    public let installation: UUID
    public let environment: AccountEnvironment
    public let recordID: Int64
    public let userID: Int64

    public init(installation: UUID, environment: AccountEnvironment, recordID: Int64, userID: Int64) {
        self.installation = installation
        self.environment = environment
        self.recordID = recordID
        self.userID = userID
    }
}

public struct ChatIdentity: Codable, Hashable, Sendable {
    public let account: AccountIdentity
    public let peerNamespace: Int32
    public let peerID: Int64

    public init(account: AccountIdentity, peerNamespace: Int32, peerID: Int64) {
        self.account = account
        self.peerNamespace = peerNamespace
        self.peerID = peerID
    }

    var supported: Bool { (0 ... 3).contains(peerNamespace) && peerID > 0 }
}

public struct AccountMembership: Codable, Equatable, Sendable {
    public let identity: AccountIdentity
    public let ownership: AccountOwnership
    public let isPremium: Bool

    public init(identity: AccountIdentity, ownership: AccountOwnership, isPremium: Bool = false) {
        self.identity = identity
        self.ownership = ownership
        self.isPremium = isPremium
    }

    func visible(in mode: AccessMode) -> Bool {
        ownership == .shared || ownership.rawValue == mode.rawValue
    }
}

public struct AccessConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let installation: UUID
    public let revision: UInt64
    public let accounts: [AccountMembership]
    public let hiddenChats: Set<ChatIdentity>
    public let hiddenChatGenerations: [ChatIdentity: UUID]
    public let selectedA: AccountIdentity
    public let selectedB: AccountIdentity

    public init(installation: UUID, revision: UInt64 = 1, accounts: [AccountMembership],
                hiddenChats: Set<ChatIdentity> = [], hiddenChatGenerations: [ChatIdentity: UUID]? = nil,
                selectedA: AccountIdentity, selectedB: AccountIdentity) throws {
        self.version = 1
        self.installation = installation
        self.revision = revision
        self.accounts = accounts
        self.hiddenChats = hiddenChats
        self.hiddenChatGenerations = hiddenChatGenerations ?? Dictionary(uniqueKeysWithValues: hiddenChats.map { ($0, UUID()) })
        self.selectedA = selectedA
        self.selectedB = selectedB
        try validate()
    }

    public func validate() throws {
        guard version == 1 else { throw AccessError.unsupportedVersion }
        guard revision > 0, (1 ... 7).contains(accounts.count),
              accounts.filter({ $0.ownership == .shared }).count == 1,
              Set(accounts.map(\.identity)).count == accounts.count,
              accounts.allSatisfy({ $0.identity.installation == installation && $0.identity.userID > 0 }) else {
            throw AccessError.invalidConfiguration
        }
        for (index, member) in accounts.enumerated() {
            for other in accounts.dropFirst(index + 1) {
                guard member.identity.recordID != other.identity.recordID,
                      member.identity.environment != other.identity.environment || member.identity.userID != other.identity.userID else {
                    throw AccessError.invalidConfiguration
                }
            }
        }
        for mode in AccessMode.allCases {
            let visible = accounts.filter { $0.visible(in: mode) }
            let maximum = visible.contains(where: \.isPremium) ? 4 : 3
            let selection = mode == .a ? selectedA : selectedB
            guard visible.count <= maximum, visible.contains(where: { $0.identity == selection }) else {
                throw AccessError.invalidConfiguration
            }
        }
        guard Set(hiddenChatGenerations.keys) == hiddenChats, hiddenChats.allSatisfy({ chat in
            chat.supported && accounts.contains(where: { $0.identity == chat.account && $0.ownership == .shared })
        }) else { throw AccessError.invalidConfiguration }
    }
}

public enum HistoryAccess: Equatable { case denied, ordinary, restrictedTranscript }
public enum AccountEnrollmentDecision: Equatable {
    case existingVisible(AccountIdentity)
    case new(AccountOwnership)
    case unavailable
}

public struct AccessModePolicy {
    public let mode: AccessMode
    let configuration: AccessConfiguration

    init(mode: AccessMode, configuration: AccessConfiguration) {
        self.mode = mode
        self.configuration = configuration
    }

    public var revision: UInt64 { configuration.revision }
    public var selectedAccount: AccountIdentity { mode == .a ? configuration.selectedA : configuration.selectedB }
    public var hiddenChatsForManagement: [ChatIdentity] {
        guard canManageHiddenChats else { return [] }
        return configuration.hiddenChats.sorted {
            if $0.peerNamespace != $1.peerNamespace { return $0.peerNamespace < $1.peerNamespace }
            return $0.peerID < $1.peerID
        }
    }

    public var visibleAccounts: [AccountIdentity] {
        guard (try? configuration.validate()) != nil else { return [] }
        return configuration.accounts.filter { $0.visible(in: mode) }.map(\.identity)
    }
    public func allowsAccount(_ account: AccountIdentity) -> Bool { visibleAccounts.contains(account) }
    public func discover(_ chat: ChatIdentity) -> Bool {
        chat.supported && allowsAccount(chat.account) && (mode == .a || !configuration.hiddenChats.contains(chat))
    }
    public func explicitOpen(_ chat: ChatIdentity) -> HistoryAccess {
        guard chat.supported, allowsAccount(chat.account) else { return .denied }
        return mode == .b && configuration.hiddenChats.contains(chat) ? .restrictedTranscript : .ordinary
    }
    public var canManageHiddenChats: Bool { mode == .a }
    public func canManageChatVisibility(_ chat: ChatIdentity) -> Bool {
        canManageHiddenChats && chat.supported && configuration.accounts.contains {
            $0.ownership == .shared && $0.identity == chat.account
        }
    }
    public func isMarkedHidden(_ chat: ChatIdentity) -> Bool {
        canManageChatVisibility(chat) && configuration.hiddenChats.contains(chat)
    }
    public var allowsPush: Bool { false }
    public var allowsBiometrics: Bool { false }

    /// Call only after authoritative self identity confirmation. A hidden collision returns
    /// the same neutral outcome as other unavailable enrollments, without another role's ID.
    public func enrollment(environment: AccountEnvironment, userID: Int64, isPremium: Bool) -> AccountEnrollmentDecision {
        guard userID > 0, (try? configuration.validate()) != nil else { return .unavailable }
        if let existing = configuration.accounts.first(where: { $0.identity.environment == environment && $0.identity.userID == userID }) {
            return existing.visible(in: mode) ? .existingVisible(existing.identity) : .unavailable
        }
        let visible = configuration.accounts.filter { $0.visible(in: mode) }
        let maximum = isPremium || visible.contains(where: \.isPremium) ? 4 : 3
        return visible.count < maximum ? .new(mode == .a ? .a : .b) : .unavailable
    }
}
