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

## Remaining implementation

The adjacent title marker, central hidden-chat search/management screen and native
account enrollment are still stage-3 work. Full B discovery/history filtering,
message provenance, notification suppression and external surfaces remain later
stages. This menu checkpoint does not complete any of those requirements.
