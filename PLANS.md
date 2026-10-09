# Dual PIN Access — progress and continuation

Last updated: 2026-10-09 (Europe/Minsk).

## Approval and current gate

The user approved `DUAL_PIN_ACCESS_PLAN_v1.txt` and authorized autonomous staged implementation, relevant checks, repairs, and local Git checkpoints. Changes to agreed product behavior require confirmation.

**Current stage: 1 — integration architecture and leakage map. Product implementation has not started. Stage 0 passed.**

The full unmodified Telegram application built successfully and was visually verified on an isolated simulator. The baseline gate is satisfied on stable Xcode 27.0, with the documented version override; it is not a reproduced Xcode-26.6 release build. Stage 1 must be verified and committed before stage 2 product implementation.

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
| 1: architecture/docs | In progress; plan approved | Updated source integration and leakage map, committed continuity documents |
| 2: infrastructure | Not started | Tested credentials/configuration/policy/epochs/transcript foundation |
| 3: lock/UI/accounts | Not started | Verified PIN selection, ownership, transitions and management UI |
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

1. Commit the verified stage-0 evidence.
2. Complete architecture/interface documentation and the integration/leakage matrix against actual upstream components.
3. Verify documentation links and consistency with the approved behavior; commit stage 1.
4. Begin stage 2 with isolated policy/security tests; do not claim any UI integration until its later stages are implemented and verified.

## Commits

- `79a4fc3024`: approved text plan, `AGENTS.md`, `PLANS.md`, and baseline documentation. Documentation checkpoint only; no product implementation.
- `350ea8d941`: reproducible resource-limited original simulator runner, Metal tooling repair, and baseline host evidence. No app code changes.

## Resume rules

- Inspect `git status`, this file, and the last build log before rerunning work.
- Never infer success from a cached artifact, a running Bazel process, or partial compilation.
- Use the freshly produced IPA, not a possibly stale archive-root directory.
- Stop at an objective external blocker only after reasonable independent diagnosis; preserve commands, exact failure, attempted solutions, and the next actionable step.
