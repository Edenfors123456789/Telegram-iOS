# Stage 5b: external surfaces

Approved behaviour: plan §7 "Остальные внешние поверхности". Push itself is in [PUSH.md](PUSH.md).

| Surface | Plan | Status |
|---|---|---|
| Notification Service / Content extensions | Not in the v1 app | Removed from `Telegram/BUILD` `extensions` (2026-10-11) |
| Widgets | Disable the extension and its data | Extension removed; `WidgetDataContext` is no longer created; its presentation-data files are removed at launch (`removeExternalSurfaceData`) |
| Siri / Intents | Disable the extension, shortcuts and donations | Extension removed; `donateSendMessageIntent` donates nothing; every interaction this app donated is deleted at launch (`INInteraction.deleteAll`). The call donation in `CallKitIntegration` goes with CallKit |
| Spotlight | Stop indexing, clear this fork's index | `SpotlightDataContext` is no longer created; at launch this app's searchable items (`deleteAllSearchableItems`, own index only) and the `spotlight` photo directory are removed |
| Share Extension | Keep only with its own PIN and the shared access policy | Left out of the app (2026-10-11) until that exists. As built upstream it asked for the legacy passcode, which Dual PIN sets to PIN A, so PIN B was refused as a wrong code (a tell, and a failed attempt in the shared cooldown); after PIN A or the biometric shortcut (`presentationPasscodeSettings.enableBiometrics`) it listed every account and every chat, since the hidden-chat set and the recent-search redirection exist only in the main app's process |
| Broadcast / ReplayKit | Permission only for the current allowed context | Pending (still built) |
| CallKit | Do not publish calls or the other party to the system interface | Off: `CallKitIntegration.isAvailable` is false (upstream's no-CallKit path, also no call donation); the local "incoming call" notification naming the caller is no longer posted (`SharedNotificationManager.postsCallNotifications`) |
| In-app calls | Only visible accounts and chats; a hidden chat's call makes no UI, sound or visible history in B | The call manager listens to the mode-visible accounts only (`activeAccountContexts`, empty while locked); a ringing call from a chat hidden from lists is dropped before presentation (no UI, no ringtone), neither answered nor declined, so it rings out and stays a missed call in A's history. Not exercised in the UI yet. Open: a call already running when the mode changes |
| Watch | Not in v1 | Off by default (`--embedWatchApp` not passed) |

The upstream sources of the removed extensions stay in the tree (their own tests still build);
only the app no longer embeds them.

Not verified on a physical device. On the simulator: launch logs and the absence of the
extensions in the built bundle (`PlugIns/`).
