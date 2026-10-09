# Integration and leakage matrix

Reference source: upstream `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838`. Paths are repository-relative. This is a verified source inventory; **all feature enforcement below is pending**. Core unit tests cannot establish coverage of these UI/extension surfaces.

| Surface | Actual integration paths | Required enforcement / acceptance |
|---|---|---|
| PIN credentials and protected resources | `submodules/PasscodeCore/Sources/Passcode.swift`; `submodules/PasscodeCore/Sources/PasscodeCrypto.swift`; `submodules/PasscodeCore/Sources/AccountManagerIntegration.swift` | One dual verification operation; durable independent budgets; role capabilities; authenticated migration; B cannot create A resource/settings sessions |
| PIN UI and settings | `submodules/PasscodeUI/Sources/PasscodeEntryController.swift`; `submodules/PasscodeUI/Sources/PasscodeEntryControllerNode.swift`; `submodules/SettingsUI/Sources/Privacy and Security/PasscodeOptionsController.swift` | Standard six-digit screen, no role chooser, no biometrics, own-PIN changes, no A options in B |
| Cover, lifecycle, navigation reset | `submodules/AppLock/Sources/AppLock.swift`; `submodules/TelegramUI/Sources/AppDelegate.swift` | Opaque cover before inactivity/snapshot; revoke old epochs; fresh permitted root before cover removal; frame-by-frame iPhone evidence |
| Account registry and switching | `submodules/TelegramUI/Sources/SharedAccountContext.swift` | Private raw registry versus visible role streams; per-role selection; guarded switch/fallback; hiding never deletes raw contexts |
| Authorization and duplicate accounts | `submodules/AuthorizationUI/Sources/AuthorizationSequencePhoneEntryController.swift` | Visible-only early phone deduplication; persisted enrollment owner; private collision guard after server identity; neutral failure and provisional-only cleanup |
| Lists, archive, folders, pins | `submodules/ChatListUI/Sources/Node/ChatListNodeLocation.swift`; `submodules/ChatListUI/Sources/Node/ChatListNode.swift`; `submodules/ChatListUI/Sources/ChatListController.swift` | Filter before pagination and pin overrides; projected last message; no hidden counts/folder names/history; preserve masked server members on edits |
| Hide actions and title markers | `submodules/ChatListUI/Sources/ChatContextMenus.swift`; `submodules/ChatListUI/Sources/Node/ChatListNodeEntries.swift` | A-only local toggle and marker; durable immediate invalidation; no B placeholder or action |
| Local/global search and recents | `submodules/ChatListUI/Sources/ChatListSearchListPaneNode.swift` | Apply policy to each local/global/recent/top/recommended result stream and pagination; drop stale results; public identity lookup never imports old hidden-dialog metadata |
| History and supplementary data | `submodules/TelegramUI/Sources/ChatHistoryViewForLocation.swift` | Transcript boundary/provenance/window and all combined initial/additional data; no old pin/keyboard/reply/media backdoor |
| Deep links and chat factories | `submodules/TelegramUI/Sources/NavigateToChatController.swift`; `submodules/TelegramUI/Sources/OpenResolvedUrl.swift`; `submodules/TelegramUI/Sources/OpenChatMessage.swift`; `submodules/AccountContext/Sources/OpenChatMessage.swift` | Guard destination and controller construction, then async completion; excluded message routes use empty B transcript; invalid account routes do not switch |
| Media and View in Chat | `submodules/TelegramUI/Components/PeerInfo/PeerInfoPaneNode`; `submodules/PeerAvatarGalleryUI`; `submodules/MediaPlayer`; `submodules/AttachmentUI` | Resolve exact listing/destination account+peer/thread; filter galleries and source messages; no cached A preview after transition |
| Unread counts and badge | `submodules/TelegramUIPreferences/Sources/RenderedTotalUnreadCount.swift`; `submodules/TelegramUI/Sources/AppDelegate.swift` | Derive visible list/folder/account counts from permitted data/projection; main icon badge always zero; handle manually-unread and expiry |
| APNs / PushKit registration and re-registration | `submodules/TelegramUI/Sources/AppDelegate.swift`; `submodules/TelegramUI/Sources/SharedAccountContext.swift` | Disable startup, auth/fallback and reset registration paths, token publication and all server registration; migrate known registrations with acknowledged unregister; never log tokens |
| Notification delivery/content/Siri donations | `Telegram/NotificationService/Sources/NotificationService.swift`; `Telegram/BUILD` | Exclude both notification extensions from final v1; never assume NSE suppression or restricted entitlements are available; remove previously delivered/pending notifications |
| Widgets / raw App Group reads | `Telegram/WidgetKitWidget/TodayViewController.swift`; `submodules/TelegramUI/Sources/WidgetDataContext.swift`; `submodules/WidgetItems` | Disable consumer target and producer data; cleanup prior widget state; do not trust only filtered main-app streams |
| Spotlight | `submodules/TelegramUI/Sources/SpotlightContacts.swift` | Stop indexing, delete this fork's previous searchable items and photos; no other app's index deletion |
| Siri / Intents | `submodules/TelegramIntents/Sources/TelegramIntents.swift`; `Telegram/BUILD` | Disable target, shortcut publication and donations globally; cleanup prior fork interactions where supported |
| Share Extension | `submodules/TelegramUI/Components/ShareExtensionContext/Sources/ShareExtensionContext.swift`; `Telegram/BUILD` | Own PIN and role grant, visible-only accounts/recipient data, epoch checks before send; does not unlock main app; no direct raw-registry fallback |
| Calls and CallKit | `submodules/TelegramCallsUI/Sources/CallKitIntegration.swift`; `submodules/TelegramUI/Sources/SharedAccountContext.swift` | No CallKit or VoIP push; in-app call surfaces obey visible accounts/chats and epoch; no implicit transcript activation or transfer of previous-role call |
| ReplayKit / Broadcast | `Telegram/BroadcastUpload/BroadcastUploadExtension.swift` | Role-bound permission; stop on lock/revoke/transition; no retained old frames; physical-device verification needed |
| Stories, bots, Mini Apps, pickers, contacts, downloads | `submodules/TelegramUI`; `submodules/ChatListUI`; `submodules/ContactListUI` | Inventory individual consumers during integration; route/content decisions at entry and rendering, no unsupported surface silently declared covered |
| Caches, logs, local DB, backups and exports | `submodules/BuildConfig/Sources/BuildConfig.m`; `submodules/Postbox`; main/extension logging consumers | Mode-local presentation caches; no sensitive debug/export surfaces in B; avoid secret logs; document retained raw DB and manual/export/backup limits |

## Route rules

- Account visibility, chat discovery, message history and explicit opening are different permissions. An explicit source link can create an empty B transcript; ordinary suggestions/counters cannot activate one.
- A permitted parent/controller does not authorize every thread, message, file, quote or async child result.
- Public contact/profile identity is not proof that local hidden history is allowed. Literal copied/forwarded content already present in a permitted message is not semantic isolation.
- Unknown routes/namespaces remain closed until mapped and tested. Maintain neutral ordinary UI behavior; no "hidden" or "restricted" placeholders in B.
- Each asynchronous adapter captures and rechecks account identity, role, policy revision and epoch. Do not use one static global mode boolean across main app and extensions.

## Notifications and external limits

The approved v1 disables all push in both modes rather than attempting unreliable client-only suppression. Clean installation with its own bundle identity, no APNs/VoIP registration and no local message notifications is the target. Old tokens require server unregister acknowledgement; removing a delivered item cannot undo previous text exposure or sound. Other clients and exported media remain outside this fork's control.

Primary references:

- https://core.telegram.org/api/push-updates
- https://core.telegram.org/method/messages.readHistory
- https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.filtering

## Required evidence per surface

Record enforcement symbols/paths, exact tests or manual steps, observed result, upstream SHA/toolchain, and one of: implemented+verified, safely closed, or documented limitation. Real-iPhone checks must include background/termination/reboot, bad PIN/offline/network changes, app-switcher snapshots, calls/extensions and no intermediate A frames. A test using synthetic data must never authorize a real account or send real messages.
