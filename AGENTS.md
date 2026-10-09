# Telegram-iOS Dual PIN Access

## Authority and scope

- Follow the user's approved `DUAL_PIN_ACCESS_PLAN_v1.txt`. The plan was approved on 2026-10-09 (Europe/Minsk).
- Work in stages. Do not begin the next implementation stage until the preceding stage has fresh verification.
- **Do not modify product code until a successful build of the unmodified upstream Telegram application has been recorded.** Documentation, isolated build artifacts, and environment diagnosis are permitted before that gate.
- Ask the user before changing agreed application behavior. Routine technical diagnosis and fixes within that behavior are already authorized.
- Keep `PLANS.md` current after material progress, failures, checks, and commits. Record enough information for another session to resume.
- Make focused local Git commits for completed stages and useful recoverable checkpoints. Do not stage unrelated files, caches, signing material, or credentials.

## Approved behavior

- Two different six-digit PINs; no biometric unlock or recovery shortcut.
- One shared primary account; additional accounts belong exclusively to A or B. Accounts added in B are not visible in A. Reauthorizing an existing account must not transfer it between modes.
- A sees full history of its visible accounts. B sees permitted chats; an explicitly opened hidden chat uses a fresh local B transcript with a rolling seven-day window.
- B transcript: include new incoming messages after its synchronized boundary and outgoing messages originating in B; exclude old history and A-originating outgoing messages. Do not delete server history.
- Normal Telegram read receipts are an accepted consequence.
- Disable all message push, VoIP push, message notification sounds/vibration, and app icon badges in both modes. Disable widgets, Spotlight/Siri publication, and CallKit.
- Protect app-switcher snapshots and every transition with an opaque cover. Do not expose previous-mode frames, navigation, search, previews, or stale callbacks.
- This is local access control, not independent cryptographic isolation of all Telegram account databases.

## Repository work

- Upstream baseline: `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838`. Preserve a record of product differences against this commit.
- Read relevant nested `AGENTS.md` instructions before editing their directories. Consult bounded sections of `CLAUDE.md` and targeted `rg` searches for architecture and build details.
- Use upstream Bazel/Make tooling for the full application. A single module compiling does not establish application build success.
- Use the installed `systematic-debugging`, `tdd`, and `verification-before-completion` skills as appropriate. Test behavior and security boundaries, not copies of implementation calculations.
- Do not use private signing repositories, source shell startup files for credentials, print secrets, or access unrelated production bots/WDA sessions.
- Simulator baseline builds may use upstream-provided profile fixtures; these do not establish device signing or grant restricted Apple entitlements. Do not import fixture private keys or install fixture-signed builds on physical devices.
- Do not kill unrelated Xcode or simulator processes. Check project-generation tooling for broad process termination before invoking it.
- Keep failure evidence and build outputs under ignored `build-input/dual-pin-stage0/`; store shareable commands and conclusions in documentation.

## Verification and reporting

- Record exact commands, exit status, relevant failures, toolchain versions, upstream SHA, and artifact identity.
- Compare failures with baseline before attributing them to Dual PIN changes. Do not report tests as passing when they did not execute.
- Separate compilation, simulator launch, automated tests, and real-iPhone verification.
- Treat unknown/corrupt access configuration and stale access grants as denied; never restore unrestricted UI as a fallback.
- No live account authorization, real-message sending, destructive device resets, or unrelated production operations are needed for isolated baseline checks.
