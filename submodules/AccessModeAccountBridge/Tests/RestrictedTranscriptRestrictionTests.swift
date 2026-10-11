import XCTest
import Foundation
@testable import AccessModeCore
@testable import AccessModeAccountBridge
import Postbox

/// Core's transcript snapshot becomes the Postbox history restriction that shows it.
final class RestrictedTranscriptRestrictionTests: XCTestCase {
    private let account = AccountIdentity(installation: UUID(), environment: .production, recordID: 1, userID: 1)
    private var chat: ChatIdentity { ChatIdentity(account: self.account, peerNamespace: 0, peerID: 50) }
    private var peerId: PeerId { PeerId(namespace: PeerId.Namespace._internalFromInt32Value(0), id: PeerId.Id._internalFromInt64Value(50)) }

    private func id(_ value: Int32, namespace: Int32 = 0, chat: ChatIdentity? = nil) -> TranscriptMessageID {
        TranscriptMessageID(chat: chat ?? self.chat, namespace: namespace, id: value)
    }
    private func messageId(_ value: Int32, namespace: Int32 = 0) -> MessageId {
        MessageId(peerId: self.peerId, namespace: namespace, id: value)
    }
    private func snapshot(boundary: TranscriptBoundary? = TranscriptBoundary(maximumMessageIDs: [0: 100], serverTimestamp: 2_000),
        windowStart: Int64 = 1_000, serverIDs: Set<TranscriptMessageID>? = nil, deleted: Set<TranscriptMessageID>? = nil) -> RestrictedTranscriptSnapshot {
        RestrictedTranscriptSnapshot(boundary: boundary, windowStart: windowStart, sendRandomIDs: [777],
            sendServerIDs: serverIDs ?? [self.id(120)], deleted: deleted ?? [self.id(130)])
    }

    func testEveryFieldIsCarriedOver() throws {
        let restriction = try XCTUnwrap(RestrictedTranscriptRestriction.historyRestriction(chat: self.chat, snapshot: self.snapshot()))
        XCTAssertEqual(restriction.boundary, MessageHistoryRestriction.Boundary(maximumMessageIds: [0: 100], serverTimestamp: 2_000))
        XCTAssertEqual(restriction.windowStart, 1_000)
        XCTAssertEqual(restriction.outgoingGloballyUniqueIds, [777])
        XCTAssertEqual(restriction.outgoingMessageIds, [self.messageId(120)])
        XCTAssertEqual(restriction.deletedMessageIds, [self.messageId(130)])
        XCTAssertTrue(restriction.includes(id: self.messageId(101), timestamp: 2_100, flags: [.Incoming], globallyUniqueId: nil))
        XCTAssertFalse(restriction.includes(id: self.messageId(99), timestamp: 2_100, flags: [.Incoming], globallyUniqueId: nil))
        XCTAssertFalse(restriction.includes(id: self.messageId(102), timestamp: 2_100, flags: [], globallyUniqueId: 5))
        XCTAssertTrue(restriction.includes(id: self.messageId(120), timestamp: 2_100, flags: [], globallyUniqueId: nil))
        XCTAssertTrue(restriction.includes(id: self.messageId(-1, namespace: 1), timestamp: 2_100, flags: [], globallyUniqueId: 777))
        XCTAssertFalse(restriction.includes(id: self.messageId(130), timestamp: 2_100, flags: [.Incoming], globallyUniqueId: nil))
    }

    func testAnOfflineTranscriptAdmitsNoIncoming() throws {
        let restriction = try XCTUnwrap(RestrictedTranscriptRestriction.historyRestriction(chat: self.chat, snapshot: self.snapshot(boundary: nil)))
        XCTAssertNil(restriction.boundary)
        XCTAssertFalse(restriction.includes(id: self.messageId(500), timestamp: 3_000, flags: [.Incoming], globallyUniqueId: nil))
    }

    func testValuesPostboxCannotHoldRefuseTheRestriction() {
        let other = ChatIdentity(account: self.account, peerNamespace: 0, peerID: 51)
        XCTAssertNil(RestrictedTranscriptRestriction.historyRestriction(chat: self.chat, snapshot: self.snapshot(windowStart: Int64(Int32.max) + 1)))
        XCTAssertNil(RestrictedTranscriptRestriction.historyRestriction(chat: self.chat, snapshot: self.snapshot(boundary: TranscriptBoundary(maximumMessageIDs: [0: 1], serverTimestamp: Int64(Int32.max) + 1))))
        XCTAssertNil(RestrictedTranscriptRestriction.historyRestriction(chat: self.chat, snapshot: self.snapshot(serverIDs: [self.id(5, chat: other)])))
        XCTAssertNil(RestrictedTranscriptRestriction.historyRestriction(chat: self.chat, snapshot: self.snapshot(deleted: [self.id(5, chat: other)])))
        XCTAssertNil(RestrictedTranscriptRestriction.historyRestriction(chat: ChatIdentity(account: self.account, peerNamespace: 0, peerID: 0x0100_0000_0000_0000), snapshot: self.snapshot(serverIDs: [], deleted: [])))
    }
}
