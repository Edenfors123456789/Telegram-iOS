# AccessModeCore integration contract

Status: stage-2 foundation verified; not wired to Telegram's UI, history, account manager or notification services. This module alone does not provide Dual PIN behavior in the running app.

## Authentication and configuration

`AccessCredentialStore.initialize` is initial-only. Its synchronous `prepareProtectedResources` hook runs under the initial-only file lock after config/PIN validation and proof construction but before vault publication. Existing owner authentication and preserved legacy resource keys are mandatory in the product adapter. Missing/corrupt/unsupported existing state cannot be reset by initialization. `isConfigured` returns false only for an absent vault; invalid/unsupported state or unavailable Keychain throws. There is no biometric/recovery API. Use the fork's own bundle/App Group namespace and Keychain service, never another application's production store.

Both six-digit ASCII PIN records are checked for each normal candidate. Verification failure commits the applicable independent budgets before returning; a valid B clears only B's budget. A reboot with a blocked budget starts another full 60-second delay. Grants leave the store only after the successful atomic commit; they are not Codable and have no public initializer. Changing a PIN requires its current code and invalidates prior grants.

The encrypted file uses AES-GCM with schema, namespace and envelope revision in its authenticated context, a non-synchronizing `WhenUnlockedThisDeviceOnly` Keychain key, 0600 files, a 0700 directory, backup exclusion, interprocess `flock`, atomic rename and fsync. Authenticated envelopes do not provide hardware-backed anti-rollback protection against restoration of an entire old encrypted vault with its original key. Raw Telegram databases remain outside this module's PIN encryption boundary.

Keep credential verification/file transactions off the main thread. File-backed policy validation belongs at query delivery/navigation/send boundaries, not once per displayed row. Do not retain an `AccessModePolicy` outside its coordinator callback and treat it as authorization for later work. Capture an opaque ticket and revalidate on every async delivery/side effect. The callback is synchronous; UI lifecycle and cross-process revocation notification wiring are still required in stages 3 and 5.

`AccessModeCoordinator` starts locked. UI code must install an opaque cover before locking/unlocking, prepare a fresh permitted root using the preparation ticket, then complete preparation before active operations. A late result from an old ticket does not invalidate the new preparation. A storage failure invalidates the current local presentation. A main-app lock persistently revokes grants; an extension's own unlock does not unlock/revoke the main UI.

At PIN submission call `preparePINRequest` synchronously before dispatch, then `beginUnlock(pin:request:)` off the main thread. The single-use request binds the exact coordinator/generation; a later lock makes queued work unable to begin. Cancel a discarded result using `cancelPreparation(ticket)`: stale tickets have no effect, the current preparation locks, an active ticket cannot be cancelled through this API. `cooldownRemaining` exposes only the neutral shortest all-blocked cooldown, no role label/budget.

The optional `ModePINEntryAuthentication` hook in PasscodeUI follows this contract and never issues a legacy protected-resource session. Its preparation callback must validate/build the root; there is no automatic app unlock. Main AppLock/configuration/root wiring is still pending, so this hook does not yet make the running Telegram app accept two PINs. The actual PIN node uses a stock theme/built-in wallpaper in both initial and updated presentation/keyboard data.

Configuration validates one shared primary, exact installation/environment/record/self-user identities, unique server accounts, role-local selection and visible-only Premium limits. Hidden chats belong to the shared primary. Each hidden chat has a persistent generation: unhide removes it; rehide creates a new one. No role UI may consume the complete raw registry.

## Stage-3 management commands

`coordinator.setHidden` and `selectAccount` replace authority only after the encrypted mutation commits. Their new ticket is preparing: attach the opaque cover first, discard the old query/navigation epoch, prepare the new revision/root, then complete preparation. Old tickets and cross-process old configuration grants are invalid. Hidden-management data is A-only; selection returns only the current role's account identity.

Enrollment is explicitly staged: `beginEnrollment` commits the role/flow origin before creating or exposing authorization UI; `bindEnrollment` durably binds its newly created provisional record; only `completeEnrollment` may adopt the confirmed self-user identity of that exact record. Grants, flow issuer, configuration/revocation and provisional record must all match. The permit is not Codable. An existing visible identity returns its permitted existing identity; an other-role collision returns only `unavailable`. The adapter must neutralize its own provisional session, never an existing raw account. Reusing a permit, another record, installation, issuer or revoked flow fails closed.

Lock/configuration/PIN changes abandon pending authority. Unknown crash-created records remain quarantined rather than adopted into the next mode. This foundation does not implement provisional-session cleanup, restart recovery UI, live Premium refresh, Telegram's authorization callbacks or visible account streams; those adapters remain stage-3 work. A hidden role's Premium membership cannot increase the other role's enrollment allowance.

## Initial legacy-owner migration

`PasscodeCore.DualPINLegacyMigration.install` is main-process only. Existing protection requires a current PIN-authenticated legacy `.settings` session; absent, resource-scoped, biometric or revoked sessions cannot authorize migration. Initial setup with no legacy PIN can use nil. It rewrites only the PIN wrapping around the existing resource key, preserves protected resources, creates six-digit A protection, publishes the committed legacy reference to the caller, and removes biometric tokens before publishing Dual PIN.

The caller must persist `didCommitLegacyReference` to AccountManager even if the later access-file commit fails. There is no cross-store atomic transaction: if legacy rewrap commits first but file/cleanup fails, Dual PIN remains absent, B is unavailable, and the known new A code unlocks the preserved legacy resources. Read the managed reference on restart; never restore an unsecured challenge or claim failure left the old PIN unchanged. Present a clear retry path. AccountManager delivery, interrupted setup UI and A-change synchronization are not yet wired/verified; an A PIN change must not use `AccessCredentialStore.changePIN` alone while legacy protected resources depend on A.

The hosted `//submodules/PasscodeCore:DualPINMigrationTests` target exercises the actual legacy credential crypto and resource derivation against isolated fake storage: initial setup, 4-to-6 owner migration, missing/revoked/wrong-scope owner, extension/existing-vault refusal, file commit failure, biometric cleanup failure/retry, and B's inability to obtain the A legacy resource session. It does not establish physical Keychain/App Group sharing. Run it through the same Make test command below with that target.

## Transcript adapter contract

- Only an explicit permitted B route calls `RestrictedTranscriptStore.begin`. Discovery, counters and incoming updates must not create a projection. Lists can include an activated projection using its filtered data, never the original raw dialog's preview/count.
- Obtain `TranscriptBoundary` from authoritative synchronization. Cloud peers use namespace 0; the namespace-2 secret-input contract still requires verification against the actual secret-chat engine. A timestamp from a currently loaded page is insufficient. Offline begin has no boundary and cannot admit incoming history.
- Admit only actual incoming messages with exact namespaced IDs after the boundary. Old edits, A/unknown outgoing, old replies, pins, album parts, keyboards and media must never be resolved from raw history to bypass this set. Content renderers and ancillary-data filtering are stage-4 work.
- Generate/persist a stable random ID and local ID; call `recordOutgoing` before engine enqueue. Enqueue only for `.recorded`; `.alreadyRecorded` requires reconciling the existing queue, without duplicate enqueue. The adapter must reconcile engine queue state after crashes and use the same random ID for any authorized retry.
- `acknowledge` and `applyDeletion` are trusted raw-service operations independent of UI unlock. They cannot create a B origin from an unknown outgoing message. The adapter must verify exact account/peer/random/local/server identity before calling them. ACK processing must be coordinated with the actual Postbox message replacement.
- Pass trusted server-adjusted time where available. The persisted high-water time prevents expired entries from reviving on ordinary clock rollback. This cannot prove correct elapsed time under a manipulated offline clock.
- The metadata ledger retains send provenance and tombstones; it does not delete raw/server messages. Its initial encrypted-file backend has a 4-MiB envelope cap and fails closed on overflow. Stage 4 must measure realistic transcript volumes and establish bounded compaction/engine reconciliation or a scalable backend before release. The foundation is not a completed performance guarantee.

## Verification commands

From the repository root, use stable Xcode with a scoped developer directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path submodules/AccessModeCore \
  --scratch-path build-input/dual-pin-stage2/swiftpm -Xswiftc -warnings-as-errors

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./build-input/bazel-9.2.0-darwin-arm64 test \
  //submodules/AccessModeCore:AccessModeCoreTests \
  --lockfile_mode=error --test_output=errors --cache_test_results=no \
  --jobs=3 --local_resources=memory=8192 --disk_cache=/tmp/tg-dual-pin-bazel-cache

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -u build-system/Make/Make.py \
  --bazel '/Users/negrfors/Desktop/tg fork/build-input/dual-pin-stage0/bazel-resource-limited' \
  --overrideXcodeVersion --cacheDir /tmp/tg-dual-pin-bazel-cache test \
  --configurationPath build-system/appstore-configuration.json \
  --codesigningInformationPath build-system/fake-codesigning \
  --target //submodules/AccessModeCore:AccessModeCoreIOSTests
```

The last command uses public profile fixtures for a simulator test only. Actual Keychain entitlements, physical-device protection, lifecycle frames, live engine reconciliation and every external surface need later verification; mock-key tests establish none of those device guarantees.

Fresh stage-2 results: 26 XCTest cases passed with SwiftPM and Bazel on Mac; 27 passed inside the iOS 26.5 hosted test app, including the real Security/Keychain adapter. Swift compilation treats warnings as errors. SDK-27 XCTest linking emits the pre-existing minimum-version warning (XCTest built for iOS 17 versus application deployment 15); test execution succeeded on iOS 26.5, not on a physical iOS-15 device.

The initial unhosted iOS test returned `errSecNotAvailable` even for a plain Security query. Hosting exposed `errSecMissingEntitlement`; adding a distinct ad-hoc **simulator-only** application/keychain identity to `TestsSupport/TestHost.entitlements` resolved it. No adapter protection was weakened and no test was skipped. This does not provide a signed device profile or shared App Group verification. The failed hosted run also exposed an upstream xctestrunner attachment-export exception after the genuine test failure; no external cache/tool source was patched to hide it.
