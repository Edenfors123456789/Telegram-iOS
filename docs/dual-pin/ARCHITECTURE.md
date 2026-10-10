# Dual PIN Access — approved implementation architecture

Approved behavior is defined by `../../DUAL_PIN_ACCESS_PLAN_v1.txt`. This document records integration decisions against upstream `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838`, whose full simulator build and baseline checks passed; see [BASELINE.md](BASELINE.md).

## Trust boundaries and modules

- Add `submodules/AccessModeCore` as a lightweight Swift module with its own SwiftPM and Bazel test entrypoints. Its policy, configuration validation, mode lifecycle, transcript decisions, and storage interfaces do not depend on TelegramCore/Postbox/UI generated sources.
- Keep authentication, immutable policy snapshots, persisted configuration, UI coordination, and Telegram adapters separate. Apple cryptographic/Keychain adapters may use CryptoKit/CommonCrypto/Security, preserving the upstream HMAC/PBKDF2-SHA256/AES-GCM mechanisms and 600,000–3,000,000 PBKDF2 work-factor bounds.
- A grant is an opaque result of actual credential verification. A saved mode, a UI boolean, or a decoded configuration cannot create an authenticated session. Grants bind issuer, credential/configuration revisions, role, capabilities, and access epoch.
- Raw account services/Postbox retain real data. Visible account streams, history projections, counters, and navigation are separate policy-governed consumers. Filtering a stream must not trigger account removal, logout, or database cleanup.
- Scope this as client access control. The existing database encryption parameters are independent of local PINs; no independent A/B cryptographic isolation is claimed.

## Core interfaces

| Interface | Contract |
|---|---|
| `AccessMode` / role | Locked, A/full, B/restricted; mode labels are never exposed in B UI |
| `AccountIdentity` | Installation ID, environment, record ID, confirmed self-user ID; no phone/name/index identity |
| `ChatIdentity` / message identity | Exact account identity plus namespaced peer/message IDs; topics inherit chat ownership |
| `AccessConfiguration` | Version, immutable revision, one shared primary, A/B-exclusive memberships, hidden chats, per-role selection and mode-local state |
| `AccessConfigurationStore` | Atomic encrypted read/update, compare-and-swap revision, cross-process serialization, validated schema; errors deny access |
| Credential/authentication store | Different six-digit codes; independently salted records; no plaintext PIN persistence; one dual verification operation |
| `AuthenticatedModeGrant` | Read-only verified role/capabilities; cannot grant A settings or legacy protected resources from B |
| `AccessModeCoordinator` | Serialized epoch/revision lifecycle; lock/revoke first, validate authentication, publish a new snapshot, wait for UI preparation |
| `AccessModePolicy` | Separate account visibility, discovery, explicit opening, message/media access, calls, counters, settings and extension permissions |
| `RestrictedTranscriptStore` | Durable activation boundary, admitted incoming IDs, pending B send provenance, server acknowledgements and expiry fences |

Use bounded typed decisions (deny, ordinary history, or restricted transcript) rather than a single `isHidden` boolean. Unknown accounts, unsupported namespaces, stale grants, missing configuration, and corrupt storage never fall back to full access.

## Authentication and durable state

The existing `PasscodeCredentialStore.verify` records an invalid attempt and clears attempts on success. Calling it once for A and again for B is unsafe. The dual operation must validate candidate credentials as one user input, apply role-specific persistent cooldown budgets, and issue only the matching role's capabilities. B success cannot reset A's failed-attempt budget. Maintain at least upstream's six-failures/60-second protection, with reboot/uptime handling and cross-process locking. Derive/check both configured credentials without a deliberate early-return timing discriminator.

Use role-bound authenticated encryption contexts so swapping primary/secondary records or changing identity/revision fails authentication. Calibration is bounded, and untrusted iteration counts are rejected before derivation. Do not grant authorization after a failed persistence operation or partially completed migration.

Configure both distinct six-digit PINs before enabling Dual PIN. Existing passcodes/resources require authenticated migration; preserve existing protected data and primary resource access. B never produces a full legacy `PasscodeSession`. Changes to A require A; changes to B require B. No biometric token, restore key, or B-driven primary reset exists.

Policy/configuration keys are device-local, non-synchronizing Keychain items with appropriate `ThisDeviceOnly` protection. Persist policy/configuration as an authenticated, encrypted versioned envelope; atomically replace files while holding an interprocess lock. Keep failed-attempt protection durable and separate from ordinary UI resets. Never erase existing Telegram accounts/messages as an error-recovery shortcut.

## Account enrollment and migration

- Exactly one chosen primary account is shared. Additional records belong to A or B according to the authenticated enrollment origin. Exclusive B records are absent from A's account management and UI.
- Persist a pending enrollment owner/flow identity before exposing authorization. On server identity confirmation, validate flow owner, current grant and epoch, and collisions with the full private account registry before publishing any account.
- Do not give AuthorizationUI hidden-mode phone numbers for its early duplicate-account shortcut. Successful fresh login to an existing exclusive account of the other role must not switch, transfer, or reveal it. Remove/revoke only the provisional session and show a neutral ordinary error.
- Crash-created unowned records are quarantined from visible streams. No fallback to the raw first account. Keep role-local last-selected accounts and authorization state.
- Preserve upstream normal/Premium conditions within each visible pool, up to four visible accounts; do not derive a B limit from hidden A Premium status. With one shared plus three exclusive records per role, retain up to seven distinct raw contexts safely.
- Relogin, logout, account replacement, environment changes, and group-to-supergroup migration require exact identity/alias validation; never transfer flags by phone number or display name.

## UI lifecycle and stale work

The existing AppLock snapshot contains blurred real UI and is insufficient. On main-thread inactivity, synchronously attach an opaque neutral cover, then revoke grants and invalidate queued UI work. On every active return, require a PIN. Avoid recursive locks triggered by the unlock controller itself. Do not depend on process termination.

Transition sequence: cover -> revoke old epoch -> cancel or reject old async work -> dismiss sensitive navigation/previews -> stop disallowed playback/broadcast/calls -> select an allowed account -> construct a fresh role-root UI -> confirm prepared content -> remove cover. A saved navigation stack is never restored across roles.

Each query/callback captures account identity, policy revision, role and epoch; validate again immediately before rendering, navigation, side effects or a send. B-originating queued sends retain their durable origin if acknowledgements arrive during A. Raw network processing can continue without exposing raw UI streams.

Partition UI history, search recents, drafts, pending selection, thumbnails derived from protected history, downloads/previews and scroll state by role. A B shadow draft must not overwrite an A draft containing excluded history. Preserve hidden server-folder members when B edits its projected folder.

## Restricted transcript semantics

- A hidden chat does not appear or affect counters until B explicitly opens it through an allowed route. Incoming messages do not implicitly activate it.
- Explicit opening establishes a fresh authoritative synchronization boundary before allowing incoming history. A link to an excluded message opens the empty permitted conversation without its old preview/anchor.
- After activation, show new incoming messages and B-originating outgoing messages, including their edits/deletions. Exclude all pre-boundary messages, A outgoing, and unknown outgoing provenance. Keep actual server dialogs/messages intact.
- Persist a B send's origin before queueing; reconcile local/random ID to exact server ID without duplication across crashes, acknowledgements, retries and mode changes.
- Apply the rolling 604,800-second window only to hidden-chat B projections. Ordinary permitted chats and exclusive B-account history remain ordinary Telegram history.
- Expired entries disappear from every projected surface/counter. Persist expiry fences so a clock rollback cannot revive already expired data. Use trusted server time where available; document limits of offline manipulated clocks rather than claim perfect trusted time.
- Initial offline opening cannot establish an authoritative boundary; show no old incoming history. Newly queued B sends may remain visible until connectivity establishes the boundary.
- Unhide restores ordinary history; rehide starts a new projection generation. Old view/cache results cannot survive the new generation.
- Filter ancillary history data (pins, bot keyboards, replies, cached message sources, albums, threads, media, scheduled messages and read-counter inputs), not merely visible entry arrays. Never resolve an excluded citation through raw history.
- Keep normal Telegram read receipts. Newly received/copied/forwarded content can itself mention A context; no semantic secrecy guarantee is made for literal content in permitted messages or external clients.

## Integration and verification gates

Initial owner setup captures the complete account/self-peer pool independently from AccountManager metadata. Its off-main adapter must validate that pool before owner work and again before Core publication. `validateInitialDualPINAccountState` supplies a read-only transaction snapshot with records and pending-authorization state; refusal or timeout grants no authority. This is not a lock against all later account changes: root preparation still validates actual identities against the committed configuration.

Keep account-state validation separate from `commitDualPINLegacyReference`. Once the authenticated legacy owner has been rewrapped to PIN A, acknowledge its exact AccountManager reference even if newer account metadata prevents Core initialization. Never restore the prior reference or unsecured challenge. A failed initial publication remains unconfigured and permits fresh owner-authenticated retry with the already committed new A code, preserving the original protected-resource key. Actual hosted metadata/reopen/retry tests verify this ordering; native initial setup remains pending.

The concrete path/surface matrix is [SURFACES.md](SURFACES.md). It starts as a research inventory, not a completed implementation checklist. Each row must acquire enforcement, automated/manual evidence, and supported/closed/limited status before release.

Stage 2 verifies isolated credential/configuration/policy/epoch/transcript boundaries. Stage 3 verifies actual PIN/UI/accounts. Stage 4 verifies every data/navigation surface. Stage 5 verifies zero push registration and external consumers. Stage 6 verifies final full build, regression tests, physical-iPhone behavior, performance and documented limitations. Do not label a stage complete from a foundation module compiling alone.

The approved plan already authorizes implementation after these documentation checks; do not request another architecture approval unless agreed behavior must change.
