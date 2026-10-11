# Stage 5b: external surfaces

Approved behaviour: plan §7 "Остальные внешние поверхности". Push itself is in [PUSH.md](PUSH.md).

| Surface | Plan | Status |
|---|---|---|
| Notification Service / Content extensions | Not in the v1 app | Removed from `Telegram/BUILD` `extensions` (2026-10-11) |
| Widgets | Disable the extension and its data | Extension removed; `WidgetDataContext` is no longer created; its presentation-data files are removed at launch (`removeExternalSurfaceData`) |
| Siri / Intents | Disable the extension, shortcuts and donations | Extension removed; `donateSendMessageIntent` donates nothing; every interaction this app donated is deleted at launch (`INInteraction.deleteAll`). The call donation in `CallKitIntegration` goes with CallKit |
| Spotlight | Stop indexing, clear this fork's index | `SpotlightDataContext` is no longer created; at launch this app's searchable items (`deleteAllSearchableItems`, own index only) and the `spotlight` photo directory are removed |
| Share Extension | Keep only with its own PIN and the shared access policy | Pending (still built, unprotected) |
| Broadcast / ReplayKit | Permission only for the current allowed context | Pending (still built) |
| CallKit, in-app calls | No system call UI with peer details; calls only for visible accounts/chats | Pending |
| Watch | Not in v1 | Off by default (`--embedWatchApp` not passed) |

The upstream sources of the removed extensions stay in the tree (their own tests still build);
only the app no longer embeds them.

Not verified on a physical device. On the simulator: launch logs and the absence of the
extensions in the built bundle (`PlugIns/`).
