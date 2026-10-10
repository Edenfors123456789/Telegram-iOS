# Fork build identity and signing status

User decision on 2026-10-09: choose a separate bundle ID, use publicly available API configuration for development, and inspect Apple Team IDs in the IMO iPhone project. No IMO process, profile, certificate or device was changed.

- Chosen bundle ID: `org.negrfors.telegram.dualpin`.
- Development configuration: ignored `build-input/dual-pin/configuration.development.json`, mode 0600. API values come only from the official upstream `build-system/appstore-configuration.json`; they are not copied from unrelated sessions/bot secrets.
- Candidate Apple team: `SC456JW7RP`, verified from the active iphone7 provisioning profile; expires 2027-10-03. This is a candidate for later signing, not proof that the new application identity can be provisioned.
- Other active IMO profiles use different teams: `V9VSAMLJL3`, `CS5Y7HL9X4`, `Z78N6GQ84P`, `A7Y7U3PCZJ`, `S5Q6XZRM9F`, `7FMAGQK4K8`. There is no single project-wide team ID.
- Each inspected active profile is bound to its existing explicit app ID, existing App Groups, and one registered device. None authorizes this new bundle ID or its new App Group. Renaming a profile or changing its entitlements cannot grant Apple's signed permissions.

Before a physical installation, provision this fork's main app and retained extensions under an accessible chosen team, with its own App Group and Keychain sharing. Verify the target iPhone is included and a matching private-key signing identity is available. Do not reuse IMO App Groups or modify existing working profiles to make a simulator success look like device readiness. No private key was accessed/imported during team discovery.

Telegram explicitly provides sample API credentials for testing, warns of server-side limitations and requires an own API ID before publication: [Obtaining api_id](https://core.telegram.org/api/obtaining_api_id). Public development values do not establish release readiness or guarantee that real account authorization will work. Isolated unit/simulator verification can continue without live Telegram accounts.

The stage-0 artifact remains the unmodified official bundle with its original public fixtures; changing its identity would invalidate that baseline comparison. Intermediate checks retain that fixture identity solely on the isolated no-account simulator and record changed sources/build numbers.

The separate development identity now builds through upstream configuration generation and Bazel's simulator profile-disabling flag:

```sh
python3 -u tools/dual-pin/build_development_simulator.py
```

The runner verifies the pinned Bazel digest, scopes stable Xcode to its child, overrides only an isolated ignored generated configuration module, and retains logs/result metadata/fresh IPA under `build-input/dual-pin-development/<UTC timestamp>/`. It accepts no device configuration and never reads or rewrites Apple provisioning profiles/certificates. The upstream default build remains available through ordinary Make. Do not run build commands concurrently.

For a diagnosed persistent-worker/compiler-plugin communication stall, an explicit
one-shot Swift invocation is available:

```sh
python3 -u tools/dual-pin/build_development_simulator.py --swift-strategy local
```

The default remains `worker`. Local strategy preserves compiler option values,
normalizing Make's literal copt quotes for the one-shot response-file path. It
retains the same Xcode, cache, resource limits, simulator configuration and signing
flags. Record `swift_strategy` and fresh build outcome in `result.json`; changing
strategy alone does not establish a successful build.

Verified local-strategy full application run `20261010T034434Z`: exit 0, 363.578
seconds, 1,473 actions; artifact identity/platform and SHA-256 are recorded in
`PLANS.md`. This resolves the observed compilation path, not a universal diagnosis
of every Swift stall or any physical-device signing guarantee.

Verified run `20261009T235135Z`: exit 0, 24.249 seconds, 122 actions; org.negrfors.telegram.dualpin 13.0/build 4, simulator SDK 27.0 / Xcode 27A266a. IPA 608,234,649 bytes, SHA-256 `7a304c8f8500d90d93ccb6269b5810c9e69d3ce0ba606a277a98e21e30fca182`. Zero embedded profiles; all six extension IDs use the chosen bundle prefix. Installation, ordinary onboarding, corrupt-vault denial and exact probe cleanup/restored onboarding passed on the isolated simulator. The active MobileBuildMCP profile is `tg-fork-dualpin`; `tg-fork-baseline` still selects the original fixture app.

This proves simulator packaging for the fork identity, not physical signing, live Telegram authorization or complete Dual PIN behavior. Siri/Widget/notification extensions are still packaged at this stage; their final disabling/guarding is stage-5 work. Configured PIN/account/history flows and iPhone verification remain pending.
