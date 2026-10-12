# Known limitations and device checklist (stage 6 input)

State on 2026-10-12. Each item is either a deliberate limit of the approved design, a gap found
while integrating, or something only a physical iPhone can confirm.

## By design (documented in the plan)

- Hiding is local presentation. The server dialog, the full history and A's view are unchanged;
  other Telegram clients of the same account show everything.
- Content already present in a chat B can see stays visible there: a hidden channel's posts
  forwarded into a visible chat, or the automatic copies of a hidden channel's posts in its
  **discussion group** when that group itself is not hidden. Hide the discussion group too.
  (Comment threads are built in the discussion group: with the group hidden, opening comments in
  B shows only what that group's restricted transcript admits.)
- No push in either mode: messages and calls arrive only while the app runs.
- Earlier notifications, sounds and anything another app or person saved cannot be undone.

## Gaps known in the implementation

- Storage usage: since 2026-10-12 the overall size in Data and Storage leaves out the hidden chats' cache too (`storageUsageOfChatsHiddenFromLists`; simulator: B 64.4 MB vs A 66.1 MB). The chat list's "cache is large" check still uses the raw size (a threshold, nothing shown by name).
- Counters derived on the server and shown as numbers only may still include hidden chats where
  the client has no per-chat breakdown (none found on screen; listed for the device review).
- Folder chat limit: the server's per-folder limit counts hidden chats kept in a folder.
- Privacy exception lists and the blocked list: since 2026-10-12 the restricted mode does not see
  hidden chats there (`requestAccountPrivacySettings`, `BlockedPeersContext.state`), and saving an
  exception list from it reads the server's rule first and keeps the hidden chats on their side
  (`preservingChatsHiddenFromLists`, mutation-checked). Not exercised in the UI (it would change the
  real account's privacy). The blocked list's total still comes from the server when not all pages
  are loaded.
- Secret chats: accepted on the simulator 2026-10-12 for lists and search (a secret chat from Ton2
  hidden in A: absent from B's list, and searching "Ton2" in B finds neither it nor Ton2). An
  explicit open of a secret chat in B is not possible by design (it has no public route).
- Gallery opened from outside a chat: B's global-search Media tab shows none of a hidden chat's
  album (simulator 2026-10-12); B has its own downloads list.
- Groups-in-common tab: accepted on the simulator 2026-10-12 (a group with Ton2 hidden in A; Ton2's
  profile shows Media/Links/Groups in A and only Media/Links in B, B's media tab empty).
- Story feed: compile-verified only (stories appear in the feed only for contacts; the test peer is
  not one).

## Physical iPhone checklist

1. App-switcher snapshot and the opaque cover on background, lock, termination and reboot; no
   frame of the previous mode when switching (screen recording, frame by frame).
2. PIN timing on device (simulator: PIN check ≈ 520 ms, root ≈ 120–350 ms).
3. No APNs/PushKit registration on a clean install; cancellation of earlier registrations after
   an update from a build that registered.
4. Calls: no CallKit UI, a hidden chat's call is silent in B and missed in A, a call of the other
   mode ends on unlock (all accepted on the simulator 2026-10-12).
5. Share extension with PIN A / PIN B, including with Face ID enabled in the old settings.
6. Broadcast (ReplayKit) from a group call, then a mode change.
7. Signed build: App Group and Keychain sharing between the app and the share extension.
