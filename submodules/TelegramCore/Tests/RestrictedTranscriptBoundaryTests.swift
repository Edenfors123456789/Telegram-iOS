import Foundation
import XCTest
import Postbox
import TelegramApi
@testable import TelegramCore

/// The restricted transcript's boundary comes from `messages.getPeerDialogs`: the chat's top
/// message id and the server time of the answer.
final class RestrictedTranscriptBoundaryTests: XCTestCase {
    private let userId: Int64 = 41
    private var peerId: PeerId { PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(self.userId)) }

    private func dialog(userId: Int64, topMessage: Int32) -> Api.Dialog {
        let settings = Api.PeerNotifySettings.peerNotifySettings(.init(flags: 0, showPreviews: nil, silent: nil, muteUntil: nil, iosSound: nil, androidSound: nil, otherSound: nil, storiesMuted: nil, storiesHideSender: nil, storiesIosSound: nil, storiesAndroidSound: nil, storiesOtherSound: nil))
        return .dialog(.init(flags: 0, peer: .peerUser(.init(userId: userId)), topMessage: topMessage, readInboxMaxId: 0, readOutboxMaxId: 0, unreadCount: 0, unreadMentionsCount: 0, unreadReactionsCount: 0, unreadPollVotesCount: 0, notifySettings: settings, pts: nil, draft: nil, folderId: nil, ttlPeriod: nil))
    }

    private func answer(_ dialogs: [Api.Dialog], date: Int32 = 1_800_000_000) -> Api.messages.PeerDialogs {
        return .peerDialogs(.init(dialogs: dialogs, messages: [], chats: [], users: [], state: .state(.init(pts: 1, qts: 0, date: date, seq: 1, unreadCount: 0))))
    }

    func testTheChatsTopMessageAndTheServerTimeFormTheBoundary() {
        XCTAssertEqual(restrictedTranscriptBoundary(peerId: self.peerId, peerDialogs: self.answer([self.dialog(userId: 7, topMessage: 900), self.dialog(userId: self.userId, topMessage: 512)])),
            RestrictedTranscriptBoundary(maximumMessageIds: [Namespaces.Message.Cloud: 512], serverTimestamp: 1_800_000_000))
    }

    func testAnEmptyChatHasBoundaryZero() {
        XCTAssertEqual(restrictedTranscriptBoundary(peerId: self.peerId, peerDialogs: self.answer([self.dialog(userId: self.userId, topMessage: 0)]))?.maximumMessageIds, [Namespaces.Message.Cloud: 0])
    }

    func testAnAnswerWithoutTheChatOrWithoutATimeEstablishesNothing() {
        XCTAssertNil(restrictedTranscriptBoundary(peerId: self.peerId, peerDialogs: self.answer([self.dialog(userId: 7, topMessage: 900)])))
        XCTAssertNil(restrictedTranscriptBoundary(peerId: self.peerId, peerDialogs: self.answer([self.dialog(userId: self.userId, topMessage: 5)], date: 0)))
    }
}
