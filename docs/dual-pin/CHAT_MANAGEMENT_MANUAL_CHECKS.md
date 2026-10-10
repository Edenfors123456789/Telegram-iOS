# Chat management native checks

Pending: these checks require the separate authorized-account test installation.
Component tests establish policy/storage/root-command behavior; compilation alone
does not establish native context-menu rendering or end-to-end chat filtering.

## Context menu

- Enter A and open a supported shared-account chat's menu from the chat list and
  search. Check local "Скрыть в режиме B" / "Показывать в режиме B" and the eye
  icon. Promotional or unresolved entries must not receive a visibility command.
- Test private chats, bots, groups, channels and secret chats, including a negative
  secret-chat ID. Exact account/environment/namespace/signed ID determines which
  local flag changes; display names and regular-peer aliases must not do so.
- Toggle a flag. The opaque cover must precede mutation/root teardown; a new
  permitted A root must be ready before uncovering. Reopen the menu and relaunch
  after fresh PIN entry to verify the opposite action and persistent setting.
- Keep an old menu callback, lock and enter A again on the same account. Invoke
  the old callback: it must neither toggle the setting nor reset the new root.
  Repeat after account switching, policy mutation and foreground/inactive change.
- Block credential/configuration persistence or revoke authority before the
  callback. No fallback raw root or server-side chat modification is permitted.
- A-exclusive accounts do not need a chat flag: their entire account is excluded
  from B. B and Share Extension must not receive management descriptors/actions.
  Native B remains denied at this intermediate stage; do not weaken admission to
  exercise this manually before the filtering/external-surface gates pass.

## Central management view (native acceptance pending)

- UIKit component verification: 44 hosted cases passed, including actual window
  layout, search, duplicate titles with distinct row IDs and clearing retained
  cell text before callbacks, on inactivity and on window removal. Its rendered
  attachment was visually inspected. These presentation IDs grant no authority.
- The view and native wrapper passed a full application build. Exact
  root-bound data loading and the A-only Privacy Settings route are added; their
  full application compilation passed. 131 Mac/133 hosted Core tests cover the
  root-bound load and stale/foreign/B/Share/inactive refusal. Configured native
  acceptance remains pending.
- Once connected, enter from both the shared and an A-exclusive account. The
  list must contain only the shared account's hidden chats. Equal titles,
  cloud/secret aliases and signed secret IDs must retain exact chat identity.
- Delay the peer query, lock and enter A again, then deliver the old result:
  no old names or controller may appear. Repeat with account/policy changes,
  inactivity, a detached settings page and missing local peer metadata.
- Searching must never open a conversation. Selecting a row changes only the
  local visibility flag behind the cover; it must prepare a fresh permitted root.

## Adjacent marker (native acceptance pending)

- Check the existing local hidden-eye icon beside the shared chat title in A's
  main list, archive and folders. Promotional/group-reference entries must not
  inherit it; additional accounts need no per-chat flag.
- Hide/unhide and verify that the covered replacement list immediately receives
  the new snapshot. Check initial root preparation as well as later folder lists.
- Recycle rows with a hidden and an ordinary peer; no old icon may remain on the
  ordinary row. Test identical names, cloud/secret aliases and signed secret IDs.
- Lock during asynchronous row preparation; no old row/marker may appear above
  the cover or in a new role root. Native B remains denied until later gates pass.

## Remaining implementation

Native account enrollment remains stage-3 work. The menu, central management
route and adjacent title marker passed full compilation and need native acceptance.
Full B discovery/history filtering,
message provenance, notification suppression and external surfaces remain later
stages. This menu checkpoint does not complete any of those requirements.
