# Dual PIN Access — progress and continuation

Last updated: 2026-10-09 (Europe/Minsk).

## Approval and current gate

The user approved `DUAL_PIN_ACCESS_PLAN_v1.txt` and authorized autonomous staged implementation, relevant checks, repairs, and local Git checkpoints. Changes to agreed product behavior require confirmation.

**Current stage: 0 — baseline build. Product implementation has not started.**

The next stage cannot begin until the full unmodified Telegram application builds successfully and that result is recorded. Preparing this progress file and `AGENTS.md` is continuity work for stage 0, not a claim that stage 1 is finished.

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
| 0: baseline | In progress | Full unmodified app build; baseline checks and artifact evidence |
| 1: architecture/docs | Approved plan; implementation documentation pending | Updated source integration and leakage map, committed continuity documents |
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
- Started the post-Metal full app retry through the helper. Timestamped log and JSON evidence: `build-input/dual-pin-stage0/baseline-build-*`. Result pending.

## Next actions

1. Inspect the post-Metal full baseline build, its timestamped JSON record, and exact exit status.
2. Diagnose any next failure with bounded source/log reads; prefer environment/configuration solutions that preserve upstream product code.
3. When successful, record the fresh IPA identity and compilation evidence, then run available baseline tests and isolated simulator smoke checks.
4. Commit stage-0 evidence before proceeding to implementation documentation and infrastructure.

## Commits

- `79a4fc3024`: approved text plan, `AGENTS.md`, `PLANS.md`, and baseline documentation. Documentation checkpoint only; no product implementation.

## Resume rules

- Inspect `git status`, this file, and the last build log before rerunning work.
- Never infer success from a cached artifact, a running Bazel process, or partial compilation.
- Use the freshly produced IPA, not a possibly stale archive-root directory.
- Stop at an objective external blocker only after reasonable independent diagnosis; preserve commands, exact failure, attempted solutions, and the next actionable step.
