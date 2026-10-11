import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi

/// Dual PIN restricted transcript: the history that existed when a hidden chat was opened in
/// the restricted mode. Only messages newer than this (and the mode's own sends) are shown.
public struct RestrictedTranscriptBoundary: Equatable {
    public let maximumMessageIds: [MessageId.Namespace: MessageId.Id]
    public let serverTimestamp: Int32

    public init(maximumMessageIds: [MessageId.Namespace: MessageId.Id], serverTimestamp: Int32) {
        self.maximumMessageIds = maximumMessageIds
        self.serverTimestamp = serverTimestamp
    }
}

/// From `messages.getPeerDialogs` for one cloud chat: its top message id and the server time
/// of the response. Nil when the response does not describe `peerId`.
func restrictedTranscriptBoundary(peerId: PeerId, peerDialogs: Api.messages.PeerDialogs) -> RestrictedTranscriptBoundary? {
    switch peerDialogs {
    case let .peerDialogs(data):
        let serverTimestamp: Int32
        switch data.state {
        case let .state(stateData):
            serverTimestamp = stateData.date
        }
        for dialog in data.dialogs where dialog.peerId == peerId {
            switch dialog {
            case let .dialog(dialogData):
                guard dialogData.topMessage >= 0, serverTimestamp > 0 else {
                    return nil
                }
                return RestrictedTranscriptBoundary(maximumMessageIds: [Namespaces.Message.Cloud: dialogData.topMessage], serverTimestamp: serverTimestamp)
            case .dialogFolder, .dialogCommunity:
                return nil
            }
        }
        return nil
    }
}

/// The authoritative boundary for `peerId`, or nil when it cannot be established now
/// (offline, unknown chat): the transcript then admits no incoming message.
/// A secret chat has no server history; its boundary is the newest stored message.
func _internal_restrictedTranscriptBoundary(postbox: Postbox, network: Network, peerId: PeerId) -> Signal<RestrictedTranscriptBoundary?, NoError> {
    if peerId.namespace == Namespaces.Peer.SecretChat {
        return postbox.transaction { transaction -> RestrictedTranscriptBoundary? in
            let top = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud)
            return RestrictedTranscriptBoundary(maximumMessageIds: [Namespaces.Message.Cloud: top?.id.id ?? 0], serverTimestamp: max(1, top?.timestamp ?? 1))
        }
    }
    return postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(peerId).flatMap(apiInputPeer)
    }
    |> mapToSignal { inputPeer -> Signal<RestrictedTranscriptBoundary?, NoError> in
        guard let inputPeer else {
            return .single(nil)
        }
        return network.request(Api.functions.messages.getPeerDialogs(peers: [.inputDialogPeer(.init(peer: inputPeer))]))
        |> map { result -> RestrictedTranscriptBoundary? in
            return restrictedTranscriptBoundary(peerId: peerId, peerDialogs: result)
        }
        |> `catch` { _ -> Signal<RestrictedTranscriptBoundary?, NoError> in
            return .single(nil)
        }
    }
}

public extension TelegramEngine.Messages {
    func restrictedTranscriptBoundary(peerId: EnginePeer.Id) -> Signal<RestrictedTranscriptBoundary?, NoError> {
        return _internal_restrictedTranscriptBoundary(postbox: self.account.postbox, network: self.account.network, peerId: peerId)
    }
}
