# Stage 5a: push disabled in both modes

Approved behaviour: plan §7 "Полное отключение push" (agreed, not up for change here). This file
records how it is built and what is left.

## What the build does

- **No subscription.** The app never asks for notification authorization, never registers for
  remote notifications for delivery, never keeps a PushKit (VoIP) registry, and never calls
  `account.registerDevice`. `SharedAccountContext`'s token-registration loop is gone; the tokens
  it still receives feed only the cancellation below, and sign-in never offers a push token for
  the code (`authorizationPushConfiguration` stays nil).
- **No banners.** In-app message banners (`ApplicationContext`, the only banner source) and their
  sound/vibration are off for every chat in both modes, not only for chats hidden from B.
- **Badge zero.** The app icon badge is always 0.
- **Cleanup at launch.** Delivered and pending notifications of the app are removed.
- **No permission prompts.** `registerForNotifications` reports "not authorized" without asking
  the system (every system prompt goes through it), and the start-up permission flow in
  `ApplicationContext` never offers the notifications step or sets its warning notice.
- **No "notifications are off" prompts.** Settings ▸ Notifications and Sounds drops its
  permission item and button, and `shouldDisplayNotificationsPermissionWarning` is always false
  (the Settings tab's "!" and the settings row warning).
- **Tokens stay inside.** A token is never written to the log and never reaches
  `initConnection`'s app data (`regularDeviceToken` stays nil), which upstream filled from the
  APNs token on every connection.

Code: `AppDelegate` (`acquirePushTokensForRegistrationCleanup`, `finishPushRegistrationCleanup`,
`registerForNotifications`, `resetBadge`), `SharedAccountContext.updateNotificationTokensRegistration`,
`PushRegistrationCleanupRunner`, Core `PushRegistrationCleanupLedger`
(`PushRegistrationCleanupTests`, 7 cases, mutation-checked), TelegramCore
`unregisterNotificationToken` (now reports whether the server answered instead of retrying
forever).

## Earlier registrations (installs updated from a build that registered)

Every earlier fork build ran the stock loop, so each account signed in before this build may
hold a server registration for this device's tokens. `account.unregisterDevice` needs the exact
token, which the app never stored, so the only way to name it is to ask the system again:

1. At the first launch of this build, the accounts already signed in are written to a durable
   ledger of pending unregistrations (`PushRegistrationCleanupLedger`, in `UserDefaults`), one entry per account and token type
   (APNs, VoIP). Accounts added later never enter it: they never registered.
2. While the ledger is non-empty, the app obtains the tokens transiently
   (`registerForRemoteNotifications` with Apple, a PushKit registry for VoIP). This registers
   nothing with Telegram; the tokens go only to the cleanup.
3. For each pending account whose context is active, `account.unregisterDevice` is sent for each
   token type. An entry is removed only when the server answered (`boolTrue` or `boolFalse`, both
   meaning no registration remains); an error leaves it for the next launch.
   Plan: "Неподтверждённую отмену не считать выполненной".
4. An account that is no longer signed in leaves the ledger (its `auth.logOut` ended its
   registrations with the authorization).
5. Once the ledger is empty the app unregisters from APNs and releases the PushKit registry.

Until step 3 completes for an account, the server may still push to it, as before this build.
A non-primary account is not connected on its own (`SharedWakeupManager` keeps only the primary
account connected in the foreground), so each cancellation holds
`Account.addExplicitImportantTask()` until it is answered; that counts as an important task and
keeps the account connected for the request.

The network debug log (MtProtoKit request descriptions, written only when logging is enabled)
carries every request's arguments, so the cancellation's token appears there while it runs; the
app's own log lines never contain a token.

## Not yet

- Notification Service / Content extensions still built into the app (plan: not included in the
  final v1 configuration).
- Call notifications without CallKit (`SharedNotificationManager` local call notification) and
  CallKit itself: separate item with the calls surface.
- Physical-device verification (APNs is simulated on the simulator).
