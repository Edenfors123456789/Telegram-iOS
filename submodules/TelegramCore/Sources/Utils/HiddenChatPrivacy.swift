import Foundation
import Postbox

// Dual PIN: privacy exception lists ("Always/Never share with") name users and groups. The
// restricted mode does not see the chats hidden from its lists there, and saving a list from that
// mode must not drop them from the server's rule, which it could not even see.

extension SelectivePrivacySettings {
    func mapPeers(_ f: ([PeerId: SelectivePrivacyPeer]) -> [PeerId: SelectivePrivacyPeer]) -> SelectivePrivacySettings {
        switch self {
        case let .enableEveryone(disableFor):
            return .enableEveryone(disableFor: f(disableFor))
        case let .enableContacts(enableFor, disableFor, enableForPremium, enableForBots):
            return .enableContacts(enableFor: f(enableFor), disableFor: f(disableFor), enableForPremium: enableForPremium, enableForBots: enableForBots)
        case let .disableEveryone(enableFor, enableForCloseFriends, enableForPremium, enableForBots):
            return .disableEveryone(enableFor: f(enableFor), enableForCloseFriends: enableForCloseFriends, enableForPremium: enableForPremium, enableForBots: enableForBots)
        }
    }

    var enabledPeers: [PeerId: SelectivePrivacyPeer] {
        switch self {
        case .enableEveryone:
            return [:]
        case let .enableContacts(enableFor, _, _, _), let .disableEveryone(enableFor, _, _, _):
            return enableFor
        }
    }

    var disabledPeers: [PeerId: SelectivePrivacyPeer] {
        switch self {
        case let .enableEveryone(disableFor), let .enableContacts(_, disableFor, _, _):
            return disableFor
        case .disableEveryone:
            return [:]
        }
    }
}

func excludingChatsHiddenFromLists(_ settings: SelectivePrivacySettings, _ hidden: Set<PeerId>) -> SelectivePrivacySettings {
    return settings.mapPeers { peers in peers.filter { !hidden.contains($0.key) } }
}

func excludingChatsHiddenFromLists(_ settings: AccountPrivacySettings, _ hidden: Set<PeerId>) -> AccountPrivacySettings {
    var settings = settings
    settings.presence = excludingChatsHiddenFromLists(settings.presence, hidden)
    settings.groupInvitations = excludingChatsHiddenFromLists(settings.groupInvitations, hidden)
    settings.voiceCalls = excludingChatsHiddenFromLists(settings.voiceCalls, hidden)
    settings.voiceCallsP2P = excludingChatsHiddenFromLists(settings.voiceCallsP2P, hidden)
    settings.profilePhoto = excludingChatsHiddenFromLists(settings.profilePhoto, hidden)
    settings.forwards = excludingChatsHiddenFromLists(settings.forwards, hidden)
    settings.phoneNumber = excludingChatsHiddenFromLists(settings.phoneNumber, hidden)
    settings.voiceMessages = excludingChatsHiddenFromLists(settings.voiceMessages, hidden)
    settings.bio = excludingChatsHiddenFromLists(settings.bio, hidden)
    settings.birthday = excludingChatsHiddenFromLists(settings.birthday, hidden)
    settings.giftsAutoSave = excludingChatsHiddenFromLists(settings.giftsAutoSave, hidden)
    settings.noPaidMessages = excludingChatsHiddenFromLists(settings.noPaidMessages, hidden)
    settings.savedMusic = excludingChatsHiddenFromLists(settings.savedMusic, hidden)
    return settings
}

/// `updated` as saved from the restricted mode, with the hidden chats `previous` (the server's
/// current rule) had put on either side put back on the same side, where `updated` has one.
func preservingChatsHiddenFromLists(_ updated: SelectivePrivacySettings, previous: SelectivePrivacySettings, hidden: Set<PeerId>) -> SelectivePrivacySettings {
    let enabled = previous.enabledPeers.filter { hidden.contains($0.key) }
    let disabled = previous.disabledPeers.filter { hidden.contains($0.key) }
    return updated.withEnabledPeers(enabled).withDisabledPeers(disabled)
}
