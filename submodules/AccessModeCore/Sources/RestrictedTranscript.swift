import Foundation

public struct TranscriptMessageID: Codable, Hashable, Sendable {
    public let chat: ChatIdentity
    public let namespace: Int32
    public let id: Int32

    public init(chat: ChatIdentity, namespace: Int32, id: Int32) {
        self.chat = chat
        self.namespace = namespace
        self.id = id
    }

    var supported: Bool { chat.supported && (0 ... 2).contains(namespace) && (namespace == 1 ? id != 0 : id > 0) }
}

/// Must come from the synchronized Telegram adapter, never from a visible history page.
public struct TranscriptBoundary: Codable, Equatable {
    public let maximumMessageIDs: [Int32: Int32]
    public let serverTimestamp: Int64

    public init(maximumMessageIDs: [Int32: Int32], serverTimestamp: Int64) {
        self.maximumMessageIDs = maximumMessageIDs
        self.serverTimestamp = serverTimestamp
    }

    func validate(for chat: ChatIdentity) throws {
        let namespace: Int32 = chat.peerNamespace == 3 ? 2 : 0
        guard serverTimestamp >= 0, maximumMessageIDs.count == 1,
              maximumMessageIDs[namespace].map({ $0 >= 0 }) == true else { throw AccessError.invalidConfiguration }
    }
}

public struct RestrictedTranscriptHandle {
    public let chat: ChatIdentity
    let generation: UUID
}

public struct BSendReceipt: Codable, Equatable {
    public let chat: ChatIdentity
    public let randomID: Int64
    /// Nil when the send was recorded before the engine assigned its local id; it is then
    /// known by its random id (and its server id once acknowledged).
    public let localID: TranscriptMessageID?
    let generation: UUID
}

/// What a history view needs to show this transcript (the Postbox history restriction):
/// the boundary, the window start (from the persisted high-water time, so a clock moved back
/// cannot reopen it), the B sends by random id and by acknowledged server id, and deletions.
public struct RestrictedTranscriptSnapshot: Equatable {
    public let boundary: TranscriptBoundary?
    public let windowStart: Int64
    public let sendRandomIDs: Set<Int64>
    public let sendServerIDs: Set<TranscriptMessageID>
    public let deleted: Set<TranscriptMessageID>
}

public enum BSendRegistration: Equatable {
    case recorded(BSendReceipt)
    case alreadyRecorded(BSendReceipt)
}

private struct TranscriptEntry: Codable {
    let id: TranscriptMessageID
    let timestamp: Int64
}

private struct BSendRecord: Codable {
    let receipt: BSendReceipt
    let timestamp: Int64
    var serverID: TranscriptMessageID?
    var deleted: Bool
}

private struct TranscriptProjection: Codable {
    let chat: ChatIdentity
    let generation: UUID
    var boundary: TranscriptBoundary?
    var highWaterTime: Int64
    var incoming: [TranscriptEntry]
    var deleted: Set<TranscriptMessageID>

    mutating func advance(to now: Int64) throws {
        guard now >= 0, now <= Int64.max - RestrictedTranscriptStore.window else { throw AccessError.invalidConfiguration }
        highWaterTime = max(highWaterTime, now)
        incoming.removeAll { $0.timestamp <= highWaterTime - RestrictedTranscriptStore.window }
    }
}

private struct TranscriptState: Codable {
    let version: Int
    var projections: [TranscriptProjection]
    var sends: [BSendRecord]

    func validate() throws {
        guard version == 1 else { throw AccessError.unsupportedVersion }
        guard Set(projections.map(\.chat)).count == projections.count else { throw AccessError.corrupt }
        for projection in projections {
            guard projection.chat.supported, projection.highWaterTime >= 0,
                  projection.highWaterTime <= Int64.max - RestrictedTranscriptStore.window,
                  Set(projection.incoming.map(\.id)).count == projection.incoming.count,
                  projection.incoming.allSatisfy({ $0.id.chat == projection.chat && $0.id.supported && $0.timestamp >= 0 }),
                  projection.deleted.allSatisfy({ $0.chat == projection.chat && $0.supported }) else { throw AccessError.corrupt }
            if let boundary = projection.boundary { try boundary.validate(for: projection.chat) }
        }
        var randomIDs = Set<SendRandomIdentity>()
        var localIDs = Set<TranscriptMessageID>()
        var serverIDs = Set<TranscriptMessageID>()
        for send in sends {
            let receipt = send.receipt
            guard receipt.randomID != 0, receipt.localID.map({ $0.chat == receipt.chat && $0.namespace == 1 && $0.supported }) ?? true,
                  send.timestamp >= 0,
                  send.serverID.map({ $0.chat == receipt.chat && $0.supported }) ?? true else { throw AccessError.corrupt }
            guard randomIDs.insert(SendRandomIdentity(account: receipt.chat.account, randomID: receipt.randomID)).inserted,
                  receipt.localID.map({ localIDs.insert($0).inserted }) ?? true else { throw AccessError.corrupt }
            if let serverID = send.serverID, !serverIDs.insert(serverID).inserted { throw AccessError.corrupt }
        }
    }
}

private struct SendRandomIdentity: Hashable {
    let account: AccountIdentity
    let randomID: Int64
}

/// Stores only access metadata, never message text/media. The Telegram adapter retains
/// the real queue/history and must persist provenance here before enqueueing with the same random ID.
public final class RestrictedTranscriptStore {
    public static let window: Int64 = 604_800
    private let credentials: AccessCredentialStore
    private let file: EncryptedAccessFile<TranscriptState>

    /// `directory` must not be the credential store's: every encrypted file locks
    /// `access-state.lock` in its own directory, and this store works inside the vault's lock,
    /// so sharing the directory would deadlock the first transcript operation.
    public init(directory: URL, namespace: String, keyProvider: AccessDeviceKeyProvider, credentials: AccessCredentialStore) throws {
        guard directory.standardizedFileURL.resolvingSymlinksInPath() != credentials.file.directory.standardizedFileURL.resolvingSymlinksInPath() else {
            throw AccessError.invalidConfiguration
        }
        self.credentials = credentials
        self.file = try EncryptedAccessFile(directory: directory, namespace: namespace + ".transcripts", keyProvider: keyProvider)
    }

    public func begin(chat: ChatIdentity, boundary: TranscriptBoundary? = nil, now: Int64,
                      grant: AuthenticatedModeGrant) throws -> RestrictedTranscriptHandle {
        try credentials.withValidatedGrant(grant) { config in
            guard grant.mode == .b, AccessModePolicy(mode: .b, configuration: config).explicitOpen(chat) == .restrictedTranscript,
                  let generation = config.hiddenChatGenerations[chat] else { throw AccessError.authenticationRequired }
            try boundary?.validate(for: chat)
            return try file.transaction(allowInitialization: true) { stored, _ in
                var state = stored ?? TranscriptState(version: 1, projections: [], sends: [])
                try state.validate()
                let index: Int
                if let existing = state.projections.firstIndex(where: { $0.chat == chat && $0.generation == generation }) {
                    index = existing
                    if let boundary {
                        guard state.projections[index].boundary == nil || state.projections[index].boundary == boundary else { throw AccessError.invalidTransition }
                        state.projections[index].boundary = boundary
                    }
                } else {
                    state.projections.removeAll { $0.chat == chat }
                    state.projections.append(TranscriptProjection(chat: chat, generation: generation, boundary: boundary,
                        highWaterTime: 0, incoming: [], deleted: []))
                    index = state.projections.count - 1
                }
                try state.projections[index].advance(to: now)
                stored = state
                return RestrictedTranscriptHandle(chat: chat, generation: generation)
            }
        }
    }

    /// Returns false for old/unknown/outgoing data. Admission never implicitly creates a projection.
    public func admit(_ id: TranscriptMessageID, incoming: Bool, timestamp: Int64, now: Int64,
                      handle: RestrictedTranscriptHandle, grant: AuthenticatedModeGrant) throws -> Bool {
        try mutate(handle, grant: grant) { state, index in
            try state.projections[index].advance(to: now)
            let projection = state.projections[index]
            guard incoming, id.chat == handle.chat, id.supported, let boundary = projection.boundary,
                  let maximumID = boundary.maximumMessageIDs[id.namespace], id.id > maximumID,
                  timestamp >= boundary.serverTimestamp, timestamp > projection.highWaterTime - Self.window,
                  timestamp <= projection.highWaterTime, !projection.deleted.contains(id) else { return false }
            if !projection.incoming.contains(where: { $0.id == id }) {
                state.projections[index].incoming.append(TranscriptEntry(id: id, timestamp: timestamp))
            }
            return true
        }
    }

    public func recordOutgoing(randomID: Int64, localID: TranscriptMessageID?, timestamp: Int64, now: Int64,
                               handle: RestrictedTranscriptHandle, grant: AuthenticatedModeGrant) throws -> BSendRegistration {
        try mutate(handle, grant: grant) { state, index in
            try state.projections[index].advance(to: now)
            guard randomID != 0, localID.map({ $0.chat == handle.chat && $0.supported && $0.namespace == 1 }) ?? true,
                  timestamp > state.projections[index].highWaterTime - Self.window,
                  timestamp <= state.projections[index].highWaterTime else { throw AccessError.invalidConfiguration }
            let receipt = BSendReceipt(chat: handle.chat, randomID: randomID, localID: localID, generation: handle.generation)
            if let old = state.sends.first(where: { $0.receipt.chat.account == handle.chat.account && ($0.receipt.randomID == randomID || (localID != nil && $0.receipt.localID == localID)) }) {
                guard old.receipt == receipt, !old.deleted else { throw AccessError.invalidTransition }
                return .alreadyRecorded(old.receipt)
            }
            state.sends.append(BSendRecord(receipt: receipt, timestamp: timestamp, serverID: nil, deleted: false))
            return .recorded(receipt)
        }
    }

    /// Trusted queue reconciliation is independent of UI mode. It can only map a previously
    /// durable B send; it cannot introduce provenance for an unknown outgoing message.
    public func acknowledge(_ receipt: BSendReceipt, serverID: TranscriptMessageID) throws {
        try file.transaction { stored, _ in
            guard var state = stored else { throw AccessError.invalidTransition }
            try state.validate()
            guard serverID.chat == receipt.chat, serverID.supported,
                  let index = state.sends.firstIndex(where: { $0.receipt == receipt }),
                  state.sends[index].serverID == nil || state.sends[index].serverID == serverID,
                  !state.sends.enumerated().contains(where: { $0.offset != index && $0.element.serverID == serverID }) else { throw AccessError.invalidTransition }
            state.sends[index].serverID = serverID
            stored = state
        }
    }

    public func visibleMessageIDs(handle: RestrictedTranscriptHandle, now: Int64,
                                  grant: AuthenticatedModeGrant) throws -> Set<TranscriptMessageID> {
        try mutate(handle, grant: grant) { state, index in
            try state.projections[index].advance(to: now)
            let projection = state.projections[index]
            var result = Set(projection.incoming.map(\.id)).subtracting(projection.deleted)
            for send in state.sends where send.receipt.chat == handle.chat && send.receipt.generation == handle.generation {
                if !send.deleted, send.timestamp > projection.highWaterTime - Self.window {
                    if let id = send.serverID ?? send.receipt.localID {
                        result.insert(id)
                    }
                }
            }
            return result
        }
    }

    public func snapshot(handle: RestrictedTranscriptHandle, now: Int64,
                         grant: AuthenticatedModeGrant) throws -> RestrictedTranscriptSnapshot {
        try mutate(handle, grant: grant) { state, index in
            try state.projections[index].advance(to: now)
            let projection = state.projections[index]
            let sends = state.sends.filter {
                $0.receipt.chat == handle.chat && $0.receipt.generation == handle.generation && !$0.deleted
            }
            return RestrictedTranscriptSnapshot(boundary: projection.boundary,
                windowStart: projection.highWaterTime - Self.window,
                sendRandomIDs: Set(sends.map(\.receipt.randomID)),
                sendServerIDs: Set(sends.compactMap(\.serverID)),
                deleted: projection.deleted)
        }
    }

    /// Raw server deletion updates may arrive while A is active or the UI is locked.
    public func applyDeletion(_ id: TranscriptMessageID) throws {
        try file.transaction { stored, _ in
            guard var state = stored, id.supported else { throw AccessError.invalidTransition }
            try state.validate()
            if let index = state.projections.firstIndex(where: { $0.chat == id.chat }) {
                state.projections[index].deleted.insert(id)
                state.projections[index].incoming.removeAll { $0.id == id }
            }
            for index in state.sends.indices where state.sends[index].serverID == id || state.sends[index].receipt.localID == id {
                state.sends[index].deleted = true
            }
            stored = state
        }
    }

    private func mutate<T>(_ handle: RestrictedTranscriptHandle, grant: AuthenticatedModeGrant,
                           _ body: (inout TranscriptState, Int) throws -> T) throws -> T {
        try credentials.withValidatedGrant(grant) { config in
            guard grant.mode == .b, config.hiddenChatGenerations[handle.chat] == handle.generation else { throw AccessError.staleAuthorization }
            return try file.transaction { stored, _ in
                guard var state = stored else { throw AccessError.invalidTransition }
                try state.validate()
                guard let index = state.projections.firstIndex(where: { $0.chat == handle.chat && $0.generation == handle.generation }) else { throw AccessError.staleAuthorization }
                let result = try body(&state, index)
                try state.validate()
                stored = state
                return result
            }
        }
    }
}
