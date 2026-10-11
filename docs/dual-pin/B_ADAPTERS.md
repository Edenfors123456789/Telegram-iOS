# Stage 4: restricted-mode (B) data adapters

The B root stays denied (`AppDelegate` `authorizeRoot` refuses `policy.mode == .b`) until
every row below that can show a hidden chat or its history is implemented and verified.
This file is the working order and status; [SURFACES.md](SURFACES.md) stays the inventory.

Only the shared primary account can have hidden chats (`AccessConfiguration.validate`). In B,
`AccessModePolicy.undiscoverableChats(of:)` names them for one account; it is empty in A and
for an account the mode cannot see. B never receives the management list
(`hiddenChatsForManagement` is A-only).

| # | Surface | Mechanism | Status |
|---|---|---|---|
| 1 | Chat lists: main, archive, folders, pinned, archive preview, chat pickers built on `ChatListNode` | `Postbox.addHiddenChatIds` registered by `SharedAccountContext.publishModeRoot` before the root is published, released with the root (`modeChatListExclusion`). Postbox now honours the set on every insert path, in a folder's pinned-peer space and in the folder re-add helper (`ChatListHiddenChatsTests`, 9 cases) | Implemented; Postbox/Core verified, B not admitted yet |
| 2 | Unread counters: tab badge, folder counters, archive row, a chat's back-button total | Views report the stored totals less the hidden chats' share (`HiddenChatUnreadCounters.swift`: per tag `max(count, markedUnread)` messages and one chat, filtered only if not removed from the total; per namespace for the archive row); a hidden chat's `.peer` read state is nil. Storage keeps the real totals. `HiddenChatUnreadCountersTests`, 9 cases. The app icon badge reads `Transaction.getTotalUnreadState` (raw) and is stage 5 (always zero) | Implemented; Postbox verified, B not admitted yet |
| 3 | Local search: chats/contacts section, local message search, recent searches, recent/top peers | Postbox `searchPeers` drops hidden chats from the chats category (a hidden chat with a contact is still found as that contact, as in the contact list) and local `searchMessages` drops their messages (`HiddenChatSearchTests`, 6 cases). `_internal_recentlySearchedPeers` and `_internal_recentPeers` filter through `withChatsHiddenFromLists` (`HiddenChatSearchResults.swift`), which also covers the share sheet and the recent-peers row that call them directly | Implemented; Postbox/TelegramCore verified, B not admitted yet |
| 4 | Server search (`messages.searchGlobal`/in-chat search via `_internal_searchMessages`, `contacts.search` via `_internal_searchPeers`) | Messages of hidden chats leave the result, its read states, thread data and `totalCount`; the account's own peer matches (`myResults`) leave out hidden chats, public matches stay (opening one is an explicit route, row 6). `HiddenChatSearchResultsTests`, 4 cases (mutation-checked) | Implemented; B not admitted yet |
| 5 | Chat history of a hidden chat opened explicitly in B | Design in [B_TRANSCRIPT.md](B_TRANSCRIPT.md). Postbox history restriction on every view of the chat (5a); confirmed album sends adopted by id; Core snapshot → restriction mapping; boundary from `messages.getPeerDialogs`. Native: the B root registers an empty restriction for every undiscoverable chat at publish; `navigateToChatController` turns the first open into boundary fetch → `openRestrictedTranscript` → restriction set to the snapshot → send recorder (`installStoreMessageAction`, Core record by random id + admission in the same transaction) → chat controller; failure leaves it closed. Compile- and lower-layer-verified only (B not admitted). Pending: expiry while viewing, deletions into Core, chat-screen auxiliary features (5c) | Implemented below the UI; UI checks pending |
| 6 | Explicit open routes: deep links, contacts, profile, global search result | Route through `explicitOpen`, construct the restricted controller, never the ordinary one | Pending |
| 7 | Profile shared media, gallery, "View in Chat", calls tab, downloads | Filter by message peer and transcript admission | Pending |
| 8 | In-app notification banners | `ApplicationContext` drops `stateManager.notificationMessages` items of chats hidden from lists (`Postbox.chatIdsHiddenFromLists()`), before the banner and its sound; the only banner source (`ChatMessageNotificationItem`). Also after an explicit open: a hidden chat never surfaces on its own. Push itself is stage 5 | Implemented; compile-verified |
| 9 | Drafts, search recents, scroll state | Drafts/scroll state: a restricted chat's history view gets no stored interface state, and `engine.peers.get/setOpaqueChatInterfaceState` neither read nor write it (so A's local and cloud draft stay as they were and B's typing is never uploaded); cloud draft updates from the server still land. Search recents: the B root redirects `RecentlySearchedPeerIds` to its own list (`RestrictedModeRecentlySearchedPeerIds` = 1002) through `Postbox.addOrderedItemListRedirection` (`OrderedItemListRedirectionTests`, 3 cases), so neither mode sees the other's searches. Other recents (stickers, emoji, GIFs, inline bots) are not partitioned yet | Drafts and search recents implemented |

## Notes

- The Postbox hidden set is in memory only, keyed by peer id, reference counted per
  registration. It existed upstream for the folder-link preview, which only needed the initial
  fill; new messages, pins and folder re-evaluation could put a hidden chat back. Those paths
  now check it. It does not touch counters (row 2) or message history views (row 5).
- Searches read the hidden set once per subscription (`Postbox.chatIdsHiddenFromLists()`),
  after the root registered it; only the mode root changes it, and it rebuilds its searches.
- A crash drops the set together with every view, so no stale B list survives a relaunch; the
  next B root registers it again before publishing.
- A chat whose identity cannot be expressed as a Postbox peer id makes the B root fail rather
  than show it.
