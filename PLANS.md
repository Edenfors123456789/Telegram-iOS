# Dual PIN Access — progress and continuation

Last updated: 2026-10-10 (Europe/Minsk).

## Approval and current gate

The user approved `DUAL_PIN_ACCESS_PLAN_v1.txt` and authorized autonomous staged implementation, relevant checks, repairs, and local Git checkpoints. Changes to agreed product behavior require confirmation.

**Current stage: 3 — lock/UI/accounts integration. Stages 0, 1 and 2 passed. Opaque-cover/lifecycle hardening is being integrated; actual Dual PIN selection, enrollment and account visibility are not connected yet.**

The full unmodified Telegram application built successfully and was visually verified on an isolated simulator. The baseline gate is satisfied on stable Xcode 27.0, with the documented version override; it is not a reproduced Xcode-26.6 release build. Architecture and integration paths were checked against the approved behavior and current source tree; stage 2 is authorized.

## Repository and environment

- Workspace: `/Users/negrfors/Desktop/tg fork`.
- Branch: `codex/telegram-ios`.
- Upstream: `https://github.com/TelegramMessenger/Telegram-iOS.git`.
- Baseline SHA: `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838` (2026-10-07).
- All 13 Git submodules match the recorded upstream references.
- Host: Apple Silicon, 10 CPUs, 16 GiB RAM; macOS 27.0.1 (26A434).
- Upstream pins: Xcode 26.6; Bazel 9.2.0. Bazel SHA-256 matches `versions.json`.
- Installed stable Xcode: `/Applications/Xcode.app`, 27.0 (27A266a). Global selection remains Xcode-beta 27.0 (27A5228h); use process-scoped `DEVELOPER_DIR` rather than changing global selection.

## Stage status

| Stage | Status | Gate |
|---|---|---|
| 0: baseline | Passed | Full original app build exit 0; 42 host cases + 306 iOS cases; isolated simulator onboarding |
| 1: architecture/docs | Passed | Approved behavior mapped to source; 41 surface paths verified; architecture and leakage documentation |
| 2: infrastructure | Passed | 26 Mac cases (SwiftPM/Bazel), 27 hosted iOS cases including real Keychain; transcript/policy/storage/revocation verified |
| 3: lock/UI/accounts | In progress | Verified PIN selection, ownership, transitions and management UI |
| 4: filtering/history | Not started | Verified surface coverage, seven-day projection and stale-result rejection |
| 5: notifications/external | Not started | Verified no push registration and guarded/disabled external surfaces |
| 6: stabilization | Not started | Final build/tests, iPhone checklist, performance comparison, limitations |

## Stage 0 evidence and investigations

- Prior `Make.py --help`: succeeded.
- Prior strict build: stopped before compilation because installed Xcode 27.0 differs from 26.6.
- Prior Xcode-managed simulator attempt with `--overrideXcodeVersion`: analysis failed because `Widget.mobileprovision` was not generated.
- Prior SwiftPM `PasscodeCore` tests: did not execute; missing generated FlatSerialization sources and a dependency identity conflict.
- The README explicitly supports `--overrideXcodeVersion` and simulator builds without a device signing identity.
- The repository provides simulator profile fixtures matching the upstream application/extension bundle IDs. These can satisfy analysis inputs without using any private signing repository or importing certificates.
- `Make.py --bazelArguments` is parsed but not wired into build invocation in this baseline. Do not rely on it to limit resources or disable profile inputs; diagnose separately if needed.
- Started a full native upstream Make build with stable Xcode, `--overrideXcodeVersion`, fixture profiles, `debug_sim_arm64`, and `--lock`. Log: `build-input/dual-pin-stage0/baseline-simulator-build.log`.
- Full build result: exit 1 after successful analysis of the complete app (1,223 packages, 74,806 configured targets). The missing Widget profile is resolved. Compilation stopped at `WallpaperBackgroundShaders.air` because Xcode's Metal Toolchain component is absent.
- Completed the supported repair: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain`, exit 0. Xcode reports component 27A266a installed; `xcrun metal --version` succeeds (32023.921). Download log: `build-input/dual-pin-stage0/metal-toolchain-download.log`.
- No product source has been modified.
- Baseline host tests completed with exit 0: `//submodules/UrlWhitelist:UrlWhitelistTests`, `//third-party/libprisma:SyntaxHighlighterTests`, and `//submodules/MTProtoRustEngine:MTProtoRustEngineMappingTests`; 3/3 Bazel test targets passed. These are component tests, not full application build evidence. Log: `build-input/dual-pin-stage0/baseline-host-tests.log`.
- Added `tools/dual-pin/build_original_simulator.py`, a stage-0 build orchestration helper, not app product code. It refuses changed product files/submodule pins, verifies Bazel's digest, delegates to upstream Make.py, and records logs/exit status/IPA SHA-256. A generated ignored launcher adds only resource limits (3 jobs, 8192 MiB memory scheduling, 2 Swift workers), compensating for the unwired `--bazelArguments` option without editing upstream tooling.
- Post-Metal full app retry passed: exit 0, 834.901 seconds, 6,104 executed actions. Evidence: `build-input/dual-pin-stage0/baseline-build-20261009T191730Z.json` and matching log.
- IPA: 604,373,337 bytes; SHA-256 `d15924a64def71b005f02ae7f3f317156fa407b0b1a3548334e4a65a10612c7e`. Verified platform `iphonesimulator`, SDK 27.0, version 13.0/build 1, min iOS 15.0. Retained copy: `build-input/dual-pin-stage0/artifacts/Telegram-original-simulator.ipa`.
- Isolated simulator: `4ED48241-0C93-4E6D-B05F-C185F0842C62`, iPhone 17 / iOS 26.5, name `TG Fork Baseline - isolated`. MobileBuildMCP installed/launched the IPA; screenshot and semantic UI show onboarding and Start Messaging. No real account was authorized.
- Initial headless accessibility snapshot failed; opening the Simulator frontend resolved it. Capture evidence: `baseline-smoke.json` and `baseline-onboarding.jpg` in the ignored evidence directory.
- iOS `//submodules/TextFormat:TextFormatTests` passed with exit 0: 306 XCTest cases, 0 failures, 114.254 seconds overall. Log: `build-input/dual-pin-stage0/baseline-ios-tests-retry.log`. The first invocation used a relative launcher path and failed before tests; corrected to an absolute path. No upstream code changes were needed.
- Existing startup diagnostics include fresh-container atomic-state absence, `no such table: t19` messages, a missing CloudKit record, and duplicate runtime accessibility-class warnings. The app remained active on onboarding; these are recorded baseline diagnostics, not attributed to Dual PIN or declared repaired.
- Final comparison against the upstream SHA confirms no changes to product/build-system files or dependency pins.

## Next actions

1. Integrate opaque covers and immediate lifecycle locks; remove biometric entry/settings paths.
2. Integrate authenticated Dual PIN initialization/migration and grants with the standard PIN controller; never publish an unfiltered B root.
3. Split raw account processing from role-visible streams, implement exact enrollment ownership/collisions and A-only hide management; verify before stage 4.
4. User authorized choosing bundle/API development values and discovering the IMO Apple team. See `docs/dual-pin/BUILD_CONFIGURATION.md`; the ignored development JSON exists. Physical signing still needs profiles for the new bundle/App Group and the eventual target iPhone.

## Stage 1 evidence

- `docs/dual-pin/ARCHITECTURE.md` records separate authentication, policy, storage, coordinator and Telegram adapters, plus symmetric account ownership and restricted-transcript semantics.
- `docs/dual-pin/SURFACES.md` maps 41 existing source paths and identifies pending enforcement/evidence. Its introduction now distinguishes verified partial stage-3 checkpoints from complete surface acceptance.
- All referenced existing source paths were checked on disk; `git diff --check` passed. Documentation is consistent with the approved six-digit/no-biometrics/no-push/account-pool/transcript behavior.
- The legacy PIN verifier increments attempts on each failed credential check; dual authentication must be a single operation with independent durable budgets, not two sequential legacy verifications.

## Stage 2 evidence

- Added independent `submodules/AccessModeCore` SwiftPM/Bazel module; it is not connected to Telegram UI yet.
- Configuration validation and policy cover exact account identity, symmetric ownership, visible-only Premium limits, hidden discovery versus explicit opening, and unknown namespaces.
- Credentials use separate salts, upstream-strength HMAC/PBKDF2-SHA256 and AES-GCM proofs; an encrypted atomic vault stores configuration and independent attempt budgets. Keychain adapter is device-local, non-synchronizing, without biometric evaluation.
- Opaque verified grants and coordinator tickets bind issuer, credential/configuration revisions, persistent revocation and local generations. Preparation cannot submit; stale callbacks are discarded; a failed persistent lock still locks the local coordinator.
- Initial policy regression run failed in 5 cases as expected; corrected run passed. Security run found a coordinator invalidation defect; corrected SwiftPM run with warnings-as-errors passed 17 XCTest cases, 0 failures. Logs: `build-input/dual-pin-stage2-policy-red.log`, `dual-pin-stage2-security-tests.log`, `dual-pin-stage2-security-green.log`.
- Bazel host verification also passed: `//submodules/AccessModeCore:AccessModeCoreTests`, 17 XCTest cases, 0 failures, warnings-as-errors (log `build-input/dual-pin-stage2-bazel-checkpoint.log`).
- Expanded foundation passed 23 XCTest cases through Bazel on Mac and the iOS 26.5 simulator; 0 failures. Includes durable restricted transcript boundary, offline pending sends, restart/ACK in A, deletion, seven-day expiry/clock rollback and rehide-generation rejection. Logs: `dual-pin-stage2-bazel-tests.log` and `dual-pin-stage2-ios-tests.log` under `build-input/`.
- Further tests passed 26 cases on Mac (SwiftPM and Bazel). An initial real iOS Keychain-adapter test exposed `errSecNotAvailable` (-25291), also for a plain query; that failed run had 27 cases and 2 assertions in the adapter test. Evidence: `build-input/dual-pin-stage2-final-ios.log` and `dual-pin-stage2-keychain-probe.log`.
- Resolved that failure with a hosted test app and its unique simulator application/keychain entitlements: actual Keychain test passed without skips or weaker storage protection. Final hosted iOS run: 27 cases, 0 failures, Bazel exit 0, 47.750 seconds (`build-input/dual-pin-stage2-hosted-entitled-ios.log`). Unhosted and host-without-entitlements failures remain recorded; the failed hosted run also hit an upstream xctestrunner failure-report export exception.
- Stage-2 source and whitespace review completed; transcript metadata backend limits and all pending adapter/device guarantees are explicit in `docs/dual-pin/INFRASTRUCTURE.md`. No PIN UI, account filtering, notifications or actual history adapters are implemented yet.

## Commits

- `79a4fc3024`: approved text plan, `AGENTS.md`, `PLANS.md`, and baseline documentation. Documentation checkpoint only; no product implementation.
- `350ea8d941`: reproducible resource-limited original simulator runner, Metal tooling repair, and baseline host evidence. No app code changes.
- `f6d3e99743`: verified original full simulator build, launch and 306 iOS tests; stage 0 gate passed.
- `5c28249fce`: approved integration architecture, verified source-path leakage matrix; stage 1 passed.
- `a646e1c8dc`: recoverable stage-2 checkpoint, 17 verified foundation cases (not the whole stage).
- `947f725815`: completed stage-2 foundation, transcript provenance/expiry, 26 Mac and 27 hosted iOS cases including actual Keychain.
- `0a57eadb37`: verified stage-3 lifecycle/opaque-cover checkpoint; full build, isolated launch, 28 Mac / 29 iOS core cases and 2 cover cases. Not the whole stage.
- `7d93c2f653`: verified durable account/visibility command checkpoint; 36 Mac / 37 iOS cases and full app build. Native account-manager/management UI integration remains pending.
- `c92bdab368`: verified standard-PIN adapter and initial legacy-owner migration checkpoint; 41 Mac / 42 iOS core cases, 5 migration cases and full app build. AppLock activation/setup/root/account adapters remain pending.

## Stage 3 evidence and pending work

- Added `AccessModeUI` opaque black cover. A red hosted UI test exposed transparent pixels; corrected cover and row-stride-aware pixel assertions passed 2 iOS cases, 0 failures (exit 0, 37.679 seconds, `build-input/dual-pin-stage3-cover-green.log`). The failed run stalled in Xcode failure-diagnostics export; only its identified task-owned xcodebuild process was terminated after preserving test output. No unrelated Xcode/device processes were changed.
- Both existing window covers now retain no underlying screenshot/theme imagery. Main-app inactivity synchronously installs the cover and invalidates pending PIN results before queued lifecycle delivery; every inactive return requires a PIN. Legacy unlock applies in the verified callback's main-thread turn instead of queueing a later unlock behind a new lock.
- PIN controller ignores biometric callbacks/modes; settings no longer offer biometric unlock or an autolock grace interval. Remaining biometric backend cleanup and complete dual setup/migration integration are pending.
- New PIN lifecycle regressions reject verification across inactivity alone (before background), synchronous invalidation, and dismissal. SwiftPM warnings-as-errors: 28 cases, 0 failures, exit 0 (`build-input/dual-pin-stage3-pin-lifecycle.log`). This verifies the independent state machine, not all application frames.
- Full application build passed: exit 0, 62.585 seconds, 80 executed actions, stable Xcode 27, upstream public configuration/profile fixtures, `debug_sim_arm64`, build number 3. Log/metadata: `build-input/dual-pin-stage3/app-cover-build.log` and `.json`. IPA 605,146,457 bytes, SHA-256 `e450ac1673c12beba8baa22a89daca38c02222ff94f908874f3bd2798cebbe72`. Fixture identity is for isolated no-account simulator regression only; it is not the chosen fork identity or device-signing readiness.
- Fresh artifact installed/launched on the isolated simulator (PID 85167); screenshot and semantic snapshot confirm ordinary Telegram onboarding. Evidence: `app-cover-launch.json`, `app-cover-onboarding.jpg`. No actual account/PIN was configured; this smoke check does not prove mode transition/frame secrecy.
- Hosted iOS core verification passed: exit 0, 53.009 seconds overall, 29 XCTest cases, 0 failures, including real Keychain and PIN lifecycle (`core-ios-tests.log`, `core-ios-xctest.log`).
- Next: save the verified lifecycle checkpoint, then continue authenticated initialization/migration and role-visible account integration. Stage 3 remains incomplete; B must not be published before its guarded root/data adapters are ready.
- Added durable coordinator commands for hide/selection revisions and provisional account enrollment ownership. A new preparing ticket replaces old authority only after commit; both roles keep independent selection. Enrollment binds an exact provisional record and confirmed server identity, returns neutral other-role collisions and rejects stale/replayed flows. No raw account is deleted by these commands.
- Account-command tests initially failed compilation because the APIs were not implemented; those tests did not execute (`account-commands-red.log`). Final Mac run: 36 XCTest cases, 0 failures, warnings-as-errors. Hosted iOS run: 37 cases, 0 failures, exit 0, 55.223 seconds (`account-commands-final-mac.log`, `account-commands-ios.log`, `account-commands-ios-xctest.log`). Includes commit failure, exact record binding/replay, hidden Premium quota, restart persistence and other-role ownership denial.
- Full app verification of the added commands passed: exit 0, 33.682 seconds, 29 executed actions (`account-commands-app-build.log`). Real Telegram enrollment/cleanup, migration UI and account stream adapters remain pending; isolated core tests do not establish their correctness.
- Added single-use PIN requests captured before dispatch; inactive locks reject work that has not started yet. Abandoned results cancel only their own preparation, without disturbing a newer ticket. Neutral cooldown exposes no per-role budget and remains durable across reboot. Mac 39 cases / hosted iOS 40 cases passed (`pin-request-green.log`, `pin-request-ios.log`, `pin-request-ios-xctest.log`); iOS elapsed 58.288 seconds.
- Added an optional Dual PIN adapter to the actual standard PasscodeEntryController. It uses the coordinator instead of issuing a legacy PasscodeSession, forces six digits and leaves the cover/PIN input in preparation until the root adapter succeeds. It is not supplied by AppLock yet: no B root is enabled. Full app compile before final presentation/migration additions passed (49.535 seconds, `pin-adapter-app-build.log`). The PIN node now uses a fixed stock theme/wallpaper, including keyboard presentation data, to remove prior-account background clues; actual PIN visual/interaction verification remains pending.
- Added `DualPINLegacyMigration` in PasscodeCore: main-process initial-only setup, verified legacy settings capability, A rewrap of the existing resource key, biometric-token cleanup and legacy-reference publication before access-vault commit. If access-file/cleanup fails after rewrap, B is not published and the known new A code still accesses the original legacy resources. Do not restore an unsecured challenge; UI must deliver the committed legacy reference and provide a clear retry path.
- Migration's first build failed before tests due to an escaping closure signature; corrected to a synchronous nonescaping initialization callback. Hosted iOS migration tests then passed: 5 cases, 0 failures, exit 0, 52.284 seconds overall (`owner-migration-ios.log` failure, `owner-migration-ios-retry.log`, `owner-migration-ios-xctest.log`). Tests use real legacy credential crypto with isolated fake storage and encrypted access files; they do not prove App Group/Keychain sharing on a real device.
- Initialization core regressions passed on Mac: 41 cases, 0 failures (`initialization-mac.log`), including failed owner preparation, existing-vault protection, invalid codes before legacy mutation and unavailable-key status errors. Final hosted core run passed 42 cases, 0 failures, exit 0, 57.435 seconds (`initialization-ios*`). Full app verification passed: exit 0, 341.703 seconds, 527 actions (`owner-migration-app-build.log`); adding the legacy-to-core dependency invalidated many cached downstream modules.
- Native-window investigation identified modal siblings above Telegram's container. A first component relying on layer zPosition failed 4 pixel assertions in 4 executed iOS cases (`native-cover-green.log`, `native-cover-failed-xctest.log`). Tests completed but xcodebuild stalled in failure diagnostics; after 3:22 only verified task-owned PID 96328 was terminated, with exact ownership evidence recorded. No unrelated process was stopped.
- Replaced it with an app-owned `SnapshotProtectedWindow` that synchronously keeps the opaque cover last after native additions/reordering/layout. NativeWindow now inherits it and blocks delegated touches while protected. AppDelegate installs this before inactivity locking and keeps it until active return has an internal lock barrier and native sheets are dismissed; ticket matching prevents stale foreground/dismiss callbacks uncovering a newer lock.
- The actual-native-host test's first build failed before execution because its internal hit-test hook needed `@testable import Display` (`native-cover-fixed.log`). The corrected target then timed out before any tests: a process sample demonstrated injected AsyncDisplayKit `+[ASDisplayNode load]` waiting on UIKit application-context preload while the latter waited on dyld (`native-cover-fixed-retry.log`, `native-cover-injection-timeout-xctest.log`, `native-cover-hang.sample.txt`). The upstream runner itself interrupted/rebooted its task-owned simulator and Bazel timed out; no unrelated process was killed. Moved Display into a dedicated UI test executable, matching normal app loading, without changing product initialization. Hosted run passed 5 cases; final additional reorder assertions also passed 5 cases, 0 failures, exit 0, 49.223 seconds (`native-cover-final.log`, `native-cover-final-xctest.log`).
- Full app verification of the native cover passed: exit 0, 394.124 seconds, 682 actions (`native-cover-app-build.log` / `.json`). Retained fresh IPA: 607,120,617 bytes, SHA-256 `8bf8e2a393e7abdcfab6e6d40969048ec2ae15813d9430fd7ba98cbd85de628e`, fixture bundle `ph.telegra.Telegraph` 13.0/build 3, simulator SDK 27 / Xcode 27A266a. Installed/launched on the isolated simulator; ordinary onboarding verified (`native-cover-launch.json`, `native-cover-onboarding.jpg`). Home/gesture actions reported success but system screenshots did not confirm background/app-switcher state; Simulator was unavailable to CUA selection/inventory. Do not treat those actions as lifecycle or snapshot proof. Actual PIN/root transitions, system keyboard/windows and physical iPhone checks remain pending. This is a recoverable stage-3 checkpoint, not completed Dual PIN activation.

## Resume rules

- Inspect `git status`, this file, and the last build log before rerunning work.
- Never infer success from a cached artifact, a running Bazel process, or partial compilation.
- Use the freshly produced IPA, not a possibly stale archive-root directory.
- Stop at an objective external blocker only after reasonable independent diagnosis; preserve commands, exact failure, attempted solutions, and the next actionable step.
