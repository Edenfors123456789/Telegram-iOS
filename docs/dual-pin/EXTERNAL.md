# Stage 5b: external surfaces

Approved behaviour: plan §7 "Остальные внешние поверхности". Push itself is in [PUSH.md](PUSH.md).

| Surface | Plan | Status |
|---|---|---|
| Notification Service / Content extensions | Not in the v1 app | Removed from `Telegram/BUILD` `extensions` (2026-10-11) |
| Widgets | Disable the extension and its data | Extension removed; `WidgetDataContext` is no longer created; its presentation-data files are removed at launch (`removeExternalSurfaceData`) |
| Siri / Intents | Disable the extension, shortcuts and donations | Extension removed; `donateSendMessageIntent` donates nothing; every interaction this app donated is deleted at launch (`INInteraction.deleteAll`). The call donation in `CallKitIntegration` goes with CallKit |
| Spotlight | Stop indexing, clear this fork's index | `SpotlightDataContext` is no longer created; at launch this app's searchable items (`deleteAllSearchableItems`, own index only) and the `spotlight` photo directory are removed |
| Share Extension | Keep only with its own PIN and the shared access policy | Done 2026-10-12 (`ShareExtensionModeAccess`, Core `AccessModePolicy.shareScope`, `ShareAccessScopeTests` 4 cases, mutation-checked). With the vault configured the extension asks for PIN A or PIN B through an extension coordinator (`AccessProcess.shareExtension`: its lock never revokes the app's grant, and it never unlocks the app); the legacy passcode no longer opens it and biometrics are off. After the PIN it keeps only that mode's accounts (selected account first) and, in its own Postbox, registers the hidden chats (lists, search, recents, an empty history restriction) and B's recent-search redirection before the sheet is built. A vault that exists but cannot be read refuses the share. The extension now carries its own App Group entitlement (`ShareEntitlements`); without it a profile-less build left the extension unable to reach the App Group (blank sheet). Simulator: PIN B sheet without Ton2/Telegram/PR GRAM and without the account switcher; PIN A sheet with them and both accounts. Known: a public global-search match of a hidden chat can still be chosen as a recipient in B (the send lands in A's history, not in B's transcript) |
| Broadcast / ReplayKit | Permission only for the current allowed context | Still built. It only feeds the screen into the app's current group call, and a group call of the other mode is left when that mode is unlocked (`endCallFromOtherMode`), so a broadcast cannot carry over; ReplayKit cannot be exercised on the simulator — physical-device check |
| CallKit | Do not publish calls or the other party to the system interface | Off: `CallKitIntegration.isAvailable` is false (upstream's no-CallKit path, also no call donation); the local "incoming call" notification naming the caller is no longer posted (`SharedNotificationManager.postsCallNotifications`) |
| In-app calls | Only visible accounts and chats; a hidden chat's call makes no UI, sound or visible history in B | The call manager listens to the mode-visible accounts only (`activeAccountContexts`, empty while locked); a ringing call from a chat hidden from lists is dropped before presentation (no UI, no ringtone), neither answered nor declined, so it rings out and stays a missed call in A's history. Accepted on the simulator 2026-10-11 (no UI or sound in B, a missed call in A). A call running when the mode changes: it survives a lock and a return to the same mode and ends when the other mode is unlocked, its screens closed before the new root is published (`SharedAccountContext.endCallFromOtherMode`, user decision 2026-10-12); accepted on the simulator 2026-10-12 (call in A, lock, PIN B: no call UI in B, `phone.discardCall` sent). The earlier simulator aborts were a pending macOS microphone prompt |
| Watch | Not in v1 | Off by default (`--embedWatchApp` not passed) |

The upstream sources of the removed extensions stay in the tree (their own tests still build);
only the app no longer embeds them.

Not verified on a physical device. On the simulator: launch logs and the absence of the
extensions in the built bundle (`PlugIns/`).
