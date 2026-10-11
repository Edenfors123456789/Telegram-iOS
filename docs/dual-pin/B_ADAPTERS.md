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
| 2 | Unread counters: tab badge, folder counters, archive row | Postbox totals include hidden chats; B must subtract or recompute from the projection | Pending |
| 3 | Local search: chats/contacts section, local message search, recent searches, recent/top peers | Filter every result stream by `discover`; drop results from a previous root | Pending |
| 4 | Global search (server `messages.searchGlobal`, contacts.search) | Drop messages of undiscoverable chats; a public peer result may open only through the explicit route | Pending |
| 5 | Chat history of a hidden chat opened explicitly in B | `RestrictedTranscriptStore` projection: empty at the boundary, new incoming and B-originated outgoing only, 7-day window | Pending (Core foundation exists) |
| 6 | Explicit open routes: deep links, contacts, profile, global search result | Route through `explicitOpen`, construct the restricted controller, never the ordinary one | Pending |
| 7 | Profile shared media, gallery, "View in Chat", calls tab, downloads | Filter by message peer and transcript admission | Pending |
| 8 | In-app notification banners | Suppress for undiscoverable chats (push itself is stage 5) | Pending |
| 9 | Drafts, search recents, scroll state | Partition per mode | Pending |

## Notes

- The Postbox hidden set is in memory only, keyed by peer id, reference counted per
  registration. It existed upstream for the folder-link preview, which only needed the initial
  fill; new messages, pins and folder re-evaluation could put a hidden chat back. Those paths
  now check it. It does not touch counters (row 2) or message history views (row 5).
- A crash drops the set together with every view, so no stale B list survives a relaunch; the
  next B root registers it again before publishing.
- A chat whose identity cannot be expressed as a Postbox peer id makes the B root fail rather
  than show it.
