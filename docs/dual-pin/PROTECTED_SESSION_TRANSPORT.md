# Protected original-session requests

This stage-3 component preserves a request's original permanent-key identity
through MTProto preparation. Request options and the native logout account
adapter are connected; the owning cleanup job and authorization routes remain
unconnected pending verification of their completion/admission boundaries.

## Implemented MTProto boundary

`MTRequestAuthKeyScope` is an immutable optional constraint with an exact positive
Int32 datacenter ID and a copied 32-byte SHA-256 permanent-key digest. Invalid
values retain their protected status and refuse submission. Ordinary upstream
requests use no scope and retain their existing behavior.

MTProto passes the actual cached `MTDatacenterAuthInfo` that supplied the key for
the current transaction into the request service. A new optional message-service
selector carries that evidence; other services keep their existing selector.
The request service checks every protected request before generating a payload,
including after retries or session changes. Legacy selector calls carry no
selected-key evidence and refuse protected requests.

For a permanent key, the actual selected 256-byte key must have the permanent
lifetime marker and match the expected digest. For temporary main/media keys,
the selected key must carry a recorded permanent digest, its own raw-key digest
and the exact datacenter. Only the successful `auth.bindTempAuthKey` callback
records those attributes, using the captured permanent key used by that bind.
Failed/skipped binds do not record them. Old temporary keys without provenance
refuse protected requests; no PFS bypass or permanent-key fallback is introduced.
Existing salt and API-initialization updates retain the attributes, and their
existing NSCoding path preserves them across reopen.

Mismatch removes only the protected request and completes once with local
`403 AUTHORIZATION_SCOPE_CHANGED`. Completion runs after transaction preparation
so a reentrant callback cannot mutate its enumeration or outgoing payload.
Ordinary requests in the same batch still prepare. This local error is not
evidence of server revocation and must not acknowledge cleanup.

The [Telegram PFS specification](https://core.telegram.org/api/pfs) explains
temporary/permanent binding. The [authorization documentation](https://core.telegram.org/api/auth)
ties authorization to an auth key, and [auth.logOut](https://core.telegram.org/method/auth.logOut)
returns `auth.LoggedOut`. A current MTContext snapshot cannot establish which
cached key a delayed request actually uses.

## Higher-level integration

TelegramCore now carries immutable `NetworkRequestAuthKeyScope` through the
lazy `Network.request` signal, engine options and actual MTRequest conversion.
Malformed scopes refuse before reaching the service. Failed Objective-C
scope/request construction also refuses, rather than dropping the constraint.
Pending moves retain the original request/options and ignore late replies from
the previous service. Both the Rust request service and session refuse protected
requests before queueing or FFI submission, including moved requests; ordinary
requests retain their previous behavior.

The owned provisional-account adapter captures an immutable original-main
scope, validates all saved datacenter fingerprints and the exact native
root/environment/claim, requires MtProtoKit and revalidates after task stopping.
Its real `auth.logOut` request forwards that scope without automatic flood waits.
Only successful scoped `auth.LoggedOut` may mint the ephemeral result after a
fresh metadata/owner/key check. Native RPC errors remain unconfirmed; missing
original evidence retains quarantine. Fingerprint observations and the result
grant no unlock/display or permission to acknowledge cleanup.

Native background folder cleanup now retains configured/provisional ownership
and checks fresh raw metadata inside a synchronous deletion transaction. It
starts denied before runtime configuration and denies Share. Error-swallowing
legacy session cleanup/temporary pruning remains quarantined in the Dual PIN
caller, preserving keys for the future exact-owner completion job. Directory
removal alone never proves a server session was revoked.

## Verification

Native scoped transport: 63-case red had 26 expected failed assertions, zero
unexpected errors; 63-case green passed. Expanded public adapter verification
passed 65 hosted cases, zero failures, exit 0, 68.510 seconds overall / 21.986
test seconds. All source hashes matched the full own-bundle app build, exit 0,
45.392 Bazel seconds, 51 actions. Artifact in
`build-input/dual-pin-stage0/native-protected-logout-20261010/app-builds/20261010T091607Z/Telegram.ipa`,
609,653,849 bytes, SHA-256
`bbf0e7f5d38247b828f1f432bee633d3707bd60afc77de03846bbe0a67ff2cd0`.
These use fake keys/RPC sources; no real server logout, launch or iPhone
acceptance is established. The first native fixture compile failure executed
no tests and is retained separately.

Existing MtProtoKit baseline: 98 cases, zero failures, exit 0, 49.994 seconds
overall / 40.179 test seconds. Actual protected-request red: 108 cases, 87
expected failed assertions, zero unexpected errors; exit 1, 47.509 seconds
overall / 40.214 test seconds. First green: 108 cases, zero failures, exit 0,
46.120 seconds overall / 40.138 test seconds.

Expanded checks passed 111 cases, zero failures, exit 0, 45.350 seconds overall /
40.191 test seconds. They drive the actual successful/failed/skipped bind callback,
archive/reopen its attributes and invoke MTProto's real preparation entry to
verify cached-key forwarding. Fixtures have no live account and use only the
existing offline context/loopback test infrastructure.

Initial scaffold and expanded-fixture invocations each failed compilation and
executed no tests. Logs retain the corrected initializer placement and missing
test-private selector declaration; stale earlier test logs are not reused.
Exact commands, source snapshots, copied XCTest streams and runner statuses are
under ignored `build-input/dual-pin-stage0/protected-session-transport-20261010/`.
Final expanded verification passed 112 cases, zero failures, exit 0, 46.119
seconds overall / 40.132 test seconds. Full own-bundle application compilation
passed exit 0, 321.027 seconds, 628 actions. Retained IPA:
`app-builds/20261010T073553Z/Telegram.ipa` under the same stage-0 directory,
609,562,185 bytes, SHA-256
`3babfcc80c11f62e923de371eaa2a782187f8cc326ef2df6d21079fede947140`.
Source digests matched the tested inputs. This verifies compilation and offline
components; no simulator launch, live server binding/logout or iPhone acceptance
is established by this checkpoint.

Before modifying TelegramCore for scope propagation, its existing broad suite
executed 166 cases with five failed assertions in two API constructor-compatibility
tests. All 164 other cases passed. These exact pre-change failures are retained
in `telegramcore-baseline*`; that suite is not reported as passing or attributed
to this transport change.

Scope propagation red executed six isolated TelegramCore cases with 18 expected
assertion failures. Actual Rust service/moved-request red executed three cases
with seven expected failures. Both had zero unexpected XCTest errors. Fresh
green passed six and three cases respectively, exit 0 (15.671 / 9.281 seconds
overall). Actual conversion/move logic and local service refusal are exercised;
the Rust fixtures create no FFI session or socket. Their ordinary-request cases
verify existing unprotected completion/missing-session behavior.

The broader post-change TelegramCore run executed 172 cases with the exact same
five failed assertions as the 166-case pre-change baseline, zero unexpected
errors, exit 1, 10.927 seconds overall / 3.407 test seconds. The exact assertion
comparison is retained as `network-session-scope-20261010/parser-failure-comparison.json`.
This is a baseline comparison, not a passing broad suite. Initial fixture and
Swift/Objective-C interoperability compile failures executed no tests and remain
in the logs. Scope integration full application compilation passed exit 0,
311.985 seconds, 629 actions. Retained artifact under
`build-input/dual-pin-stage0/network-session-scope-20261010/app-builds/20261010T075834Z/Telegram.ipa`,
609,603,001 bytes, SHA-256
`1df71c0b66d19bafb1dd20dcf71cb07be6e289382974a1d164b8ee90a190685c`.
Source digests match the verified inputs. Dependent account bridge checks also
passed 47 cases, zero failures, exit 0, 64.013 seconds overall / 13.482 test
seconds. Native cleanup admission and directory protection remain pending.
