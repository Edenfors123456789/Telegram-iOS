# B restricted transcript: design (stage 4, row 5)

Approved behaviour: plan §5 "Пустая переписка B для скрытого чата" and ARCHITECTURE.md
"Restricted transcript semantics". This file records how it is built on Telegram's data layer.

## Why a Postbox-level restriction

A chat is read through many independent message-history views: the chat itself, shared
media tabs, the gallery, music/voice playlists, the pinned-message bar, in-chat search,
"scroll to date", reply and quote previews (`associatedMessages` embedded in every rendered
message). Filtering one view leaves the others open. So, like the chat-list exclusion
(`Postbox.addHiddenChatIds`), the restriction lives in Postbox and applies to every view of
the chat while the B root holds it:

    postbox.addHistoryRestriction(peerId:, restriction:) -> Disposable

Raw storage, network processing and `Transaction` reads are unchanged: the server dialog and
the full local history stay intact (plan: "Серверные сообщения и полная история A
сохраняются").

## The predicate

`restriction.includes(message)` is evaluated on the Postbox queue from the stored message
header (`IntermediateMessage`: id, timestamp, flags, `globallyUniqueId`), never from content:

- excluded: anything in `deleted`;
- excluded: anything with `timestamp <= windowStart` (`highWaterTime - 604800`; the high-water
  time is persisted by `RestrictedTranscriptStore`, so a clock rollback cannot revive it);
- included: an incoming message with `id > boundary.maximumMessageIDs[namespace]` and
  `timestamp >= boundary.serverTimestamp` — new incoming after the boundary;
- included: an outgoing message whose `globallyUniqueId` is a recorded B send (the random id
  is persisted before enqueue and survives the local-to-server id replacement);
- everything else is excluded: pre-boundary history, A-originated and unknown outgoing.

Without a boundary (first open offline) no incoming message passes; B's own sends do.

The predicate reads an in-memory mirror (`boundary`, `windowStart`, B random ids, deletions)
owned by the native adapter and kept in step with `RestrictedTranscriptStore`, which persists
the same facts. Changing the mirror bumps a version that makes the views re-filter.

## Where Postbox applies it

1. History views: initial fill and every later insertion (the same two places that already
   honour `ignoreMessagesInTimestampRange`/`ignoreMessageIds`), for every tag/thread view of
   the chat.
2. Holes below the boundary are not requested: a restricted view must not page the old
   history in from the server just to discard it.
3. Rendered messages drop `associatedMessages` (reply/quote sources) that the restriction
   excludes, so a permitted reply never shows an old quoted message.
4. Single-message views (`messageView`) of an excluded message report no message.
5. Unread counters of the chat come from admitted messages only (the raw read state includes
   old unread history) — to settle while integrating the chat screen.

## Native adapter (later steps)

- Explicit open in B (`explicitOpen == .restrictedTranscript`): `RestrictedTranscriptStore.begin`,
  then the authoritative boundary from the server (the chat's current top message id and
  server time); register the restriction before the chat controller is built.
- Sending: generate the random id, `recordOutgoing`, add it to the mirror, then enqueue with that
  random id; `.alreadyRecorded` reconciles the existing queue instead of enqueueing again.
- Server deletions: `applyDeletion` and the mirror.
- The chat screen's auxiliary features that read raw history directly (not through a view) are
  inventoried and closed or filtered one by one.

## Known gaps for 5b

- Closed 2026-10-11: server confirmation of a single send kept the message's
  `globallyUniqueId` (`applyUpdateMessage`) but the album path (`applyUpdateGroupMessages`)
  stored the confirmed messages with `globallyUniqueId: nil`, so a B album dropped out of the
  transcript after a relaunch. The album path now keeps the random id as well
  (`testAConfirmedSendThatKeepsItsRandomIdIsAdmittedAfterARelaunch` pins the Postbox side).
  That alone did not keep an album: `messages.sendMultiMedia` answers with full
  `updateNewMessage`s, and the state manager stores them over the confirmed messages
  (`InsertExistingMessage`), with no random id because the server never sends one. Found on the
  simulator (the user's album vanished from B the moment it was sent). Postbox now keeps a stored
  message's random id when a copy without one is stored over it
  (`testAServerCopyOfABSendKeepsItsRandomId`, red → green). A single send in a private chat is
  answered with `updateShortSentMessage` and never had this problem.
- A send confirmed while the app was not running (the message arrives through `getDifference`
  instead of the send's own result) must still be matched to its recorded random id.

## Decision: no list entry, ever (user, 2026-10-11)

Asked whether a hidden chat should appear in B's chat list once it has been opened explicitly
(with a preview built from the B transcript only), the user chose "Никогда не показывать": a
hidden chat never gets a row in B, not after an explicit open and not after new messages. It is
reached again only through an explicit route (public username search, link). The transcript
itself persists between opens. This narrows ARCHITECTURE.md's "lists can include an activated
projection" to "lists never include it".

## Native wiring decisions (5c)

- The B root registers a history restriction for **every** undiscoverable chat when it is
  published, next to the chat-list exclusion. Before an explicit open there is no Core
  projection, so the restriction has no boundary and no sends: any route that reaches the chat
  without going through the explicit open shows an empty conversation (fail-safe default).
- The explicit open (contact, profile, search result, link) fetches the boundary
  (`engine.messages.restrictedTranscriptBoundary`), calls `openRestrictedTranscript` on the
  active root and replaces the chat's restriction with the snapshot (one transaction), then
  pushes the ordinary chat controller.
- Sends: Core must record the random id durably before the message is enqueued. The local
  message id is assigned by Postbox only when the message is stored, so Core's
  `recordOutgoing(localID:)` precondition does not fit the engine; the record should be keyed by
  random id, with the local id optional. To settle before wiring the composer.

## Current limitations (native wiring)

- Expiry while viewing: once a minute each opened transcript's snapshot replaces its
  restriction (`refreshModeTranscriptExpiry`); a failed snapshot closes the chat to everything.
- Confirmations are not written back to Core (`acknowledge`). Visibility does not need them:
  both confirmation paths keep the random id, so a confirmed send, album included, stays
  admitted after a restart. Core's server-id ledger stays empty (bookkeeping only).
- Server deletions remove the messages from Postbox, so they leave every view; Core's
  `applyDeletion` ledger is not fed yet.

## Beside the history views (5c, first pass)

An inventory of the chat screen, profile, gallery and calendar found ~40 reads that bypass the
history views. Closed centrally:

- Postbox views by id (`.messages`, `.messageGroup`, `.topChatMessage`) and `CachedPeerDataView`
  report excluded messages as absent; restriction changes refresh them.
- In a restricted history view: the top tagged message (bot keyboard), `.cachedPeerDataMessages`
  (the first pinned panel) and `.message(id)` extra data are filtered; the raw read state (whole
  history's unread count) is withheld; `.combinedLocation` positions ("N of M") count admitted
  messages only.
- `historyTagSummaryView` counts (profile media counts, @/reaction badges) count admitted messages.
- TelegramCore: `SparseMessageList` and `SparseMessageCalendar` (profile media grid, calendar)
  publish an empty state, `getSearchMessageCount` reports nothing and
  `searchMessageIdByTimestamp` finds nothing for a restricted chat.

Still open from the inventory: drafts and their reply (next), reply threads/comments of a hidden
channel (thread root fetched raw), gallery anchor opened from outside the chat, admin "delete all
from user" count paths not via `getSearchMessageCount`.

## Steps

5a. Postbox restriction primitive and tests (this design's "Where Postbox applies it" 1–4).
5b. Mirror object + Core/bridge adapter (boundary acquisition, sends, deletions, expiry).
5c. Chat screen in B for a hidden chat, auxiliary features.

## Decision: no calls of a hidden chat in B, not even in its transcript (user, 2026-10-12)

A call after the boundary is a new incoming message, so the transcript admitted it ("Missed Call"
inside Ton2's B transcript). Asked, the user chose "Скрывать в переписке": a hidden chat's calls
never show in B. `MessageHistoryRestriction.excludedGlobalTags` drops messages carrying the given
global tags; the app passes `[.Calls, .MissedCalls]` to every restriction it builds
(`RestrictedTranscriptRestriction.historyRestriction(…, excludedGlobalTags:)` makes the caller
choose). Tests: `testARestrictionCanLeaveOutCallsInTheTranscript` (mutation-checked),
`testExcludedGlobalTagsAreCarriedOver`. The calls tab already leaves out every message of a
chat hidden from lists (`GlobalMessageTagsView`).
