# Fork build identity and signing status

User decision on 2026-10-09: choose a separate bundle ID, use publicly available API configuration for development, and inspect Apple Team IDs in the IMO iPhone project. No IMO process, profile, certificate or device was changed.

- Chosen bundle ID: `org.negrfors.telegram.dualpin`.
- Development configuration: ignored `build-input/dual-pin/configuration.development.json`, mode 0600. API values come only from the official upstream `build-system/appstore-configuration.json`; they are not copied from unrelated sessions/bot secrets.
- Candidate Apple team: `SC456JW7RP`, verified from the active iphone7 provisioning profile; expires 2027-10-03. This is a candidate for later signing, not proof that the new application identity can be provisioned.
- Other active IMO profiles use different teams: `V9VSAMLJL3`, `CS5Y7HL9X4`, `Z78N6GQ84P`, `A7Y7U3PCZJ`, `S5Q6XZRM9F`, `7FMAGQK4K8`. There is no single project-wide team ID.
- Each inspected active profile is bound to its existing explicit app ID, existing App Groups, and one registered device. None authorizes this new bundle ID or its new App Group. Renaming a profile or changing its entitlements cannot grant Apple's signed permissions.

Before a physical installation, provision this fork's main app and retained extensions under an accessible chosen team, with its own App Group and Keychain sharing. Verify the target iPhone is included and a matching private-key signing identity is available. Do not reuse IMO App Groups or modify existing working profiles to make a simulator success look like device readiness. No private key was accessed/imported during team discovery.

Telegram explicitly provides sample API credentials for testing, warns of server-side limitations and requires an own API ID before publication: [Obtaining api_id](https://core.telegram.org/api/obtaining_api_id). Public development values do not establish release readiness or guarantee that real account authorization will work. Isolated unit/simulator verification can continue without live Telegram accounts.

The stage-0 artifact remains the unmodified official bundle with its original public fixtures; changing its identity would invalidate that baseline comparison. Subsequent fork builds will use the separate identity and must record their own artifact metadata.
