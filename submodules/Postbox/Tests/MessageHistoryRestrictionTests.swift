import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// While `Postbox.addHistoryRestriction` is held for a chat (Dual PIN's restricted transcript),
/// every history view of that chat shows only what the restriction admits: incoming messages
/// after the boundary and B's own sends, inside the window. Storage keeps the full history.
final class MessageHistoryRestrictionTests: XCTestCase {
    private var fixture: PostboxFixture!

    private let chat = MessageHistoryTableFixture.peerId(930)
    private let namespace = PostboxFixture.messageNamespace
    private let mediaTag = MessageTags(rawValue: 1 << 3)

    // Old incoming 10 and A's 11 before the boundary (max id 11, server time 1200); after it a
    // new incoming 12, B's send 13 (random id 77) and A's send 14 (random id 88).
    private let bSendRandomId: Int64 = 77

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "MessageHistoryRestrictionTests")
    }

    override func tearDown() {
        self.fixture.close()
        self.fixture = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func id(_ value: Int32) -> MessageId {
        return MessageId(peerId: self.chat, namespace: self.namespace, id: value)
    }

    private func message(_ id: Int32, timestamp: Int32, incoming: Bool, randomId: Int64? = nil, replyTo: Int32? = nil, tags: MessageTags = []) -> StoreMessage {
        var attributes: [MessageAttribute] = []
        if let replyTo {
            attributes.append(FixtureReplyAttribute(messageId: self.id(replyTo)))
        }
        return StoreMessage(id: self.id(id), customStableId: nil, globallyUniqueId: randomId, groupingKey: nil, threadId: nil, timestamp: timestamp, flags: incoming ? [.Incoming] : [], tags: tags, globalTags: [], localTags: [], forwardInfo: nil, authorId: nil, text: "m\(id)", attributes: attributes, media: [])
    }

    private func seed(holeBelow: Bool = false) {
        self.fixture.transaction { transaction in
            transaction.updatePeersInternal([FixturePeer(id: self.chat, title: "Hidden")], update: { _, updated in updated })
            transaction.updatePeerChatListInclusion(self.chat, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
            let _ = transaction.addMessages([
                self.message(10, timestamp: 1000, incoming: true, tags: self.mediaTag),
                self.message(11, timestamp: 1100, incoming: false, randomId: 55),
                self.message(12, timestamp: 1300, incoming: true, tags: self.mediaTag),
                self.message(13, timestamp: 1400, incoming: false, randomId: self.bSendRandomId),
                self.message(14, timestamp: 1500, incoming: false, randomId: 88),
            ], location: .Random)
            // A chat starts as one hole over every id; this history is fully loaded.
            transaction.removeHole(peerId: self.chat, threadId: nil, namespace: self.namespace, space: .everywhere, range: 1 ... Int32.max)
            if holeBelow {
                transaction.addHole(peerId: self.chat, threadId: nil, namespace: self.namespace, space: .everywhere, range: 1 ... 9)
            }
        }
    }

    private func restriction(boundary: Bool = true, windowStart: Int32 = 0, deleted: Set<MessageId> = []) -> MessageHistoryRestriction {
        return MessageHistoryRestriction(
            boundary: boundary ? MessageHistoryRestriction.Boundary(maximumMessageIds: [self.namespace: 11], serverTimestamp: 1200) : nil,
            windowStart: windowStart,
            outgoingGloballyUniqueIds: [self.bSendRandomId],
            deletedMessageIds: deleted
        )
    }

    @discardableResult
    private func restrict(_ restriction: MessageHistoryRestriction? = nil) -> Disposable {
        let disposable = self.fixture.postbox.addHistoryRestriction(peerId: self.chat, restriction ?? self.restriction())
        self.fixture.transaction { _ in }
        return disposable
    }

    private func observe(tag: MessageTags? = nil) -> PostboxFixture.Recorder<MessageHistoryView> {
        let tagInput: HistoryViewInputTag? = tag.flatMap { .tag($0) }
        return self.fixture.observe(self.fixture.postbox.aroundMessageHistoryViewForLocation(.peer(peerId: self.chat, threadId: nil), anchor: .upperBound, ignoreMessagesInTimestampRange: nil, ignoreMessageIds: [], count: 20, fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: [], tag: tagInput, appendMessagesFromTheSameGroup: false, namespaces: .all, orderStatistics: []) |> map { $0.0 })
    }

    private func ids(_ view: MessageHistoryView?) -> [Int32] {
        return (view?.entries ?? []).map { $0.message.id.id }
    }

    private func eventually<Value>(_ recorder: PostboxFixture.Recorder<Value>, file: StaticString = #file, line: UInt = #line, _ condition: (Value?) -> Bool) {
        let deadline = Date().addingTimeInterval(10.0)
        while !condition(recorder.values.last) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(condition(recorder.values.last), file: file, line: line)
    }

    // MARK: - Tests

    func testWithoutARestrictionTheHistoryIsComplete() {
        self.seed()
        XCTAssertEqual(self.ids(self.observe().waitForValues(count: 1).last), [10, 11, 12, 13, 14])
    }

    func testARestrictedChatShowsOnlyNewIncomingAndBSends() {
        self.seed()
        self.restrict()
        XCTAssertEqual(self.ids(self.observe().waitForValues(count: 1).last), [12, 13])
    }

    func testWithoutABoundaryOnlyBSendsShow() {
        self.seed()
        self.restrict(self.restriction(boundary: false))
        XCTAssertEqual(self.ids(self.observe().waitForValues(count: 1).last), [13])
    }

    func testTheWindowAndDeletionsExcludeMessages() {
        self.seed()
        self.restrict(self.restriction(windowStart: 1350))
        XCTAssertEqual(self.ids(self.observe().waitForValues(count: 1).last), [13], "12 is older than the window")
    }

    func testADeletedMessageIsExcluded() {
        self.seed()
        self.restrict(self.restriction(deleted: [self.id(13)]))
        XCTAssertEqual(self.ids(self.observe().waitForValues(count: 1).last), [12])
    }

    func testNewMessagesAreFilteredOnArrival() {
        self.seed()
        self.restrict()
        let recorder = self.observe()
        recorder.waitForValues(count: 1)
        self.fixture.transaction { transaction in
            let _ = transaction.addMessages([
                self.message(15, timestamp: 1600, incoming: true),
                self.message(16, timestamp: 1700, incoming: false, randomId: 99),
            ], location: .Random)
        }
        self.eventually(recorder) { self.ids($0) == [12, 13, 15] }
    }

    func testASendRecordedInTheSameTransactionShows() {
        self.seed()
        self.restrict()
        let recorder = self.observe()
        recorder.waitForValues(count: 1)
        self.fixture.transaction { transaction in
            transaction.updateHistoryRestriction(peerId: self.chat) { restriction in
                var restriction = restriction
                restriction.outgoingGloballyUniqueIds.insert(100)
                return restriction
            }
            let _ = transaction.addMessages([self.message(17, timestamp: 1800, incoming: false, randomId: 100)], location: .Random)
        }
        self.eventually(recorder) { self.ids($0) == [12, 13, 17] }
    }

    func testABSendStaysAdmittedWhenTheServerReplacesItWithoutItsRandomId() {
        // An album's confirmation stores the server messages without the random id.
        self.seed()
        self.restrict()
        let recorder = self.observe()
        XCTAssertEqual(self.ids(recorder.waitForValues(count: 1).last), [12, 13])
        self.fixture.transaction { transaction in
            transaction.updateMessage(self.id(13)) { _ in .update(self.message(20, timestamp: 1450, incoming: false)) }
            transaction.updateMessage(self.id(14)) { _ in .update(self.message(21, timestamp: 1550, incoming: false)) }
        }
        self.eventually(recorder) { self.ids($0) == [12, 20] }
        let admitted = self.fixture.transaction { $0.historyRestriction(peerId: self.chat)?.outgoingMessageIds }
        XCTAssertEqual(admitted ?? nil, [self.id(20)], "A's replaced message is not adopted")
    }

    func testATaggedViewIsRestrictedToo() {
        self.seed()
        self.restrict()
        XCTAssertEqual(self.ids(self.observe(tag: self.mediaTag).waitForValues(count: 1).last), [12])
    }

    func testAReplyDoesNotRevealItsExcludedSource() {
        self.seed()
        self.fixture.transaction { transaction in
            let _ = transaction.addMessages([self.message(18, timestamp: 1900, incoming: true, replyTo: 10), self.message(19, timestamp: 2000, incoming: true, replyTo: 12)], location: .Random)
        }
        self.restrict()
        let entries = self.observe().waitForValues(count: 1).last?.entries ?? []
        let replyToOld = entries.first(where: { $0.message.id.id == 18 })?.message
        let replyToNew = entries.first(where: { $0.message.id.id == 19 })?.message
        XCTAssertNotNil(replyToOld)
        XCTAssertNil(replyToOld?.associatedMessages[self.id(10)], "the old quoted message is not rendered")
        XCTAssertNotNil(replyToNew?.associatedMessages[self.id(12)], "an admitted source still is")
    }

    func testAnExcludedMessageHasNoSingleMessageView() {
        self.seed()
        self.restrict()
        XCTAssertNil(self.fixture.observeMessage(self.id(10)).waitForValues(count: 1).last?.message)
        XCTAssertEqual(self.fixture.observeMessage(self.id(12)).waitForValues(count: 1).last?.message?.id, self.id(12))
    }

    func testHolesBelowTheBoundaryAreNotRequested() {
        self.seed(holeBelow: true)
        let holes = self.fixture.observe(self.fixture.postbox.messageHistoryHolesView())
        func requestsThisChat(_ view: MessageHistoryHolesView?) -> Bool {
            return (view?.entries ?? []).contains { entry in
                if case let .peer(hole) = entry.hole {
                    return hole.peerId == self.chat
                }
                return false
            }
        }
        // Control: an ordinary view asks for the hole.
        let ordinary = self.observe()
        ordinary.waitForValues(count: 1)
        self.eventually(holes) { requestsThisChat($0) }
        self.fixture.close()

        self.fixture = PostboxFixture(name: "MessageHistoryRestrictionTests")
        self.seed(holeBelow: true)
        self.restrict()
        let restrictedHoles = self.fixture.observe(self.fixture.postbox.messageHistoryHolesView())
        XCTAssertEqual(self.ids(self.observe().waitForValues(count: 1).last), [12, 13])
        self.fixture.transaction { _ in }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(requestsThisChat(restrictedHoles.values.last), "the old history is not paged in")
    }

    func testReleasingTheRestrictionShowsTheFullHistory() {
        self.seed()
        let restriction = self.restrict()
        let recorder = self.observe()
        XCTAssertEqual(self.ids(recorder.waitForValues(count: 1).last), [12, 13])
        restriction.dispose()
        self.fixture.transaction { _ in }
        self.eventually(recorder) { self.ids($0) == [10, 11, 12, 13, 14] }
    }
}
