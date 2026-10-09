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
- Full build result: pending. No product source has been modified.

## Next actions

1. Inspect the running baseline build and its exact exit status.
2. Diagnose any next failure with bounded source/log reads; prefer environment/configuration solutions that preserve upstream product code.
3. When successful, record the fresh IPA identity and compilation evidence, then run available baseline tests and isolated simulator smoke checks.
4. Commit stage-0 evidence before proceeding to implementation documentation and infrastructure.

## Commits

No Dual PIN implementation commits yet. The approved text plan and continuity documents are being prepared for a local checkpoint.

## Resume rules

- Inspect `git status`, this file, and the last build log before rerunning work.
- Never infer success from a cached artifact, a running Bazel process, or partial compilation.
- Use the freshly produced IPA, not a possibly stale archive-root directory.
- Stop at an objective external blocker only after reasonable independent diagnosis; preserve commands, exact failure, attempted solutions, and the next actionable step.
