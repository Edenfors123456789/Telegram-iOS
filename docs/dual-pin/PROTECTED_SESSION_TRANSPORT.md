# Protected original-session requests

This stage-3 component preserves a request's original permanent-key identity
through MTProto preparation. Native authorization and cleanup remain closed
until the higher-level request and account adapters are connected and verified.

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

## Pending integration

Carry the immutable scope through TelegramCore request options and into
MtProtoKit, retain it when requests move between engine services, and explicitly
refuse it on engines that do not implement this boundary. Then connect the exact
owned provisional-account adapter. A fingerprint observation alone grants no
RPC, unlock, display or cleanup-completion authority. Native RPC errors remain
unconfirmed; missing original evidence retains quarantine.

## Verification

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
