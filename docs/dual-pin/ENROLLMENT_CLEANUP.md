# Provisional account ownership and cleanup

## Implemented component boundary

The encrypted Core vault retains cleanup ownership separately from transient
enrollment authorization. Exact installation, flow, mode, signed provisional
record ID and Telegram environment are recorded when binding a new auth record.
The record must not already belong to any configured account, including a role
that is invisible to the current UI. Retrying the same binding is idempotent;
another record or environment cannot replace it.

PIN/grant revocation, locking, cancellation and ordinary policy changes clear
completion authority while retaining cleanup ownership. A new enrollment cannot
start until the outstanding provisional record is resolved. Successfully adding
a new membership removes the cleanup record in the same vault transaction.
Duplicate visible identities and other-role collisions retain only the newly
created provisional record for cleanup; existing membership is unchanged.

Only the main-process coordinator can claim cleanup. The claim durably cancels
old completion authority before external cleanup starts. Its non-Codable ticket
selects the exact provisional ID/environment and grants no unlock, display,
membership transfer or enrollment completion. Claiming again is idempotent;
foreign/reopened-instance tickets and old acknowledgments cannot erase a later
owner. A fresh instance obtains a fresh local ticket for the durable claim.

`withEnrollmentCleanup` provides a pre-side-effect synchronous metadata boundary.
It validates the same exact durable owner and completion cancellation before the
callback, and keeps the vault read lock held through that callback. Old/foreign
tickets, unavailable/corrupt storage and Share are denied before the body runs.
Successful reads and throwing callbacks do not rewrite the vault, acknowledge
cleanup, change the role or grant an unlock. Acknowledgment shares this owner
validation but remains a separate operation after actual cleanup/absence proof.

The callback must be short and synchronous; do not reenter the vault or enqueue
network/async work inside it. A network cleanup job needs a fresh validation at
submission and again when its result is consumed, and must preserve pending
ownership on failure. The gate alone does not revoke a Telegram session.

## Account-directory retention

`withUnownedAccountDirectory` denies every configured membership and the exact
active or claimed provisional record, including while locked or after reopening
the vault. Missing/corrupt/unavailable state and Share cannot run its callback.
For an unowned ID, the validated interprocess read lock covers the synchronous
filesystem action, preventing concurrent enrollment from acquiring that ID
before the action returns. This gate neither rewrites state nor grants access.

`removeUnreferencedAccountDirectory` runs inside a fresh AccountManager
transaction. It retains every raw authorized/temporary record and current auth;
the view snapshot used for candidate discovery cannot grant deletion. Only the
canonical decimal UInt64 account-directory name under the actual metadata root
is accepted. Foreign roots, symbolic links, non-directories and unavailable path
metadata refuse. The caller's durable gate must execute the removal synchronously
inside that transaction; a previously returned Boolean cannot authorize later
work. Removal means only local orphan cleanup, never server-session revocation
or permission to acknowledge the provisional ledger.

`AccountDirectoryCleanupGate` begins denied before native runtime configuration.
Its coordinator snapshot is followed by a fresh durable read for each operation.
A failed/corrupt startup has no permissive fallback.

The background-cleanup adapter has a session-evidence retention option: do not
prune old temporary records or start legacy `.loggedOut` handlers. The upstream
handler swallows RPC errors before deleting metadata and cannot provide our
required original-session proof. The Dual PIN caller must retain those records
for the owned cleanup job. Ordinary upstream callers retain their existing
legacy behavior; all candidate folder deletion uses the fresh transaction.
The native SharedAccountContext supplies retention and the default-denied gate
from startup. Only the successfully constructed main-app mode runtime configures
that gate. Share always denies. The owned server/local completion job remains
pending; retained logout/temporary records are intentional quarantine meanwhile.

Directory-retention verification: five Core red cases had 25 expected failed
assertions; focused green, full 161-case Mac and 163-case hosted iOS checks
passed. Five native directory regressions produced 17 expected failures across
52 cases, then all 52 passed. Three actual background regressions expanded the
suite to 55: red had three expected failures, green passed with exit 0,
162.607 seconds overall / 14.714 test seconds. Initial fixture failures/relaunches
and the failed-test runner's post-test wait are recorded separately in PLANS.

The connected native sources passed the full own-bundle app build, exit 0,
343.662 Bazel seconds, 635 actions; saved source digests match. Retained artifact:
`build-input/dual-pin-stage0/account-directory-retention-20261010/app-builds/20261010T085519Z/Telegram.ipa`,
609,644,729 bytes, SHA-256
`6f9acf658be0203466169dcf84894f8e9c48045158a32fbed0b211d126ea7f8b`.
No actual session logout or physical-device behavior was exercised.

## Storage version and failures

First provisional binding upgrades the vault payload to version 3. Existing
ordinary version-1/2 vaults remain readable. Owner-PIN journal work preserves the
higher version, including after recovery. Earlier fork builds reject version 3
instead of ignoring its cleanup ownership. The configuration and encrypted
envelope versions are independent and remain unchanged.

The Core component can additionally persist an original-session binding for
each datacenter: a positive datacenter ID and a 32-byte SHA-256 digest, never
the raw authorization key. Binding requires the current main-app enrollment
permit, a ready access ticket and the already-bound exact provisional record.
Repeated identical binding is idempotent; changing a datacenter's digest is
denied. A durable cleanup claim cancels further binding.

The first session binding upgrades the encrypted payload to version 4.
Ordinary versions 1–3 remain readable; older cleanup records return no invented
session fingerprints. Earlier fork readers reject version 4 rather than lose
its ownership evidence. Duplicate datacenters, malformed digests, empty binding
arrays and bindings in downgraded payloads refuse access. Owner-PIN recovery
preserves version 4 and the bindings. Only a current main-app cleanup ticket can
read them after lock/reopen; this grants no account data or unlock.

The Core component can now record a verified scoped `auth.LoggedOut` result
for each exact original datacenter key and durable cleanup claim. These records
contain only the claim ID and saved key fingerprint. The first result upgrades
the encrypted payload to version 5; ordinary versions 1–4 remain readable and
return no invented confirmations. Older readers reject version 5.

Duplicate identical results are logically idempotent. Unknown/replacement keys,
old/foreign tickets and Share are denied. Duplicate datacenters, empty result
arrays, malformed keys, another claim, unbound keys and downgraded payloads
refuse access. Read-only lookup survives lock/reopen without rewriting the vault;
owner-PIN journal recovery preserves the results and version. Failed pre-write
key/filesystem operations preserve the prior bytes for exact retry.

Only the native verified opaque-response consumer may call the record method.
`AccountEnrollmentBridge.revokeSession` is that consumer: after a confirmed
scoped reply and a fresh detached-metadata check under the vault's read lock, it
records the transport's exact original key (`revokedSessionKey`) and returns
`.confirmed` only if that write succeeded. A transport with no key never sends
the request; a key that is not bound to the cleanup, or any failed vault access
after the reply, returns `.unavailable` with no receipt and keeps the ledger.
The record is written outside the read lock, since recording takes the write
lock. A record proves only its recorded scoped result;
it neither invents results for other datacenters nor grants account access,
local deletion or ledger acknowledgment. The official
[datacenter documentation](https://core.telegram.org/api/datacenter) describes
separate keys and authorization transfer; it does not establish our tested
all-datacenter logout guarantee. Final cleanup admission must resolve those
boundaries before removing the local evidence.

Acknowledgment now requires a receipt for every bound original key of the
current claim; a missing one refuses with `invalidTransition` and writes
nothing, so the ledger, the retained directory and the claim survive lock and
reopen. An owner that never bound a key needs no receipt, because authorization
may use only an already-bound original key; the native authorization route must
keep that ordering. Four Core regressions (red: five failures, one a follow-on
of the premature acknowledgment) then 171 Mac / 173 hosted Core cases passed.

Fresh receipt checks passed six focused cases, then 167 Mac and 169 hosted iOS
Core cases with zero failures. The real red had 36 expected failed assertions,
zero unexpected errors. Exact commands/results are retained under
`build-input/dual-pin-stage0/session-revocation-receipts-20261010/`.
Dependent/full-application checks are pending for this checkpoint.

This storage boundary accepts a digest from the native adapter described below.
Extraction, read-only restart reconciliation and protected request preparation
are implemented. The Core component alone does not establish original-session
provenance or server logout; actual server/device acceptance remains pending.

A new-schema bound enrollment requires its matching cleanup ledger. Missing,
aliased, inconsistent or downgraded ownership is corrupt and refuses access;
it cannot trigger fresh setup. Failed claim/ack writes preserve the exact prior
encrypted bytes for retry. A record already accepted into configuration can
never become a cleanup target. Old unexposed version-1/2 pending enrollment data
does not create new cleanup authority; unknown raw records must be quarantined,
never guessed or deleted.

## Authorization attempts (write-ahead)

A bound original key needs a server logout only if an authorizing request may
have used it. A key that never carried one was never authorized: a flow
cancelled before sign-in, or the old datacenter key a `PHONE_MIGRATE` leaves
behind. Requiring a receipt for such a key would block cleanup for ever,
because the server cannot be asked to confirm a logout of a session that never
existed, and an outstanding provisional record blocks every new enrollment.

So the ledger records which keys an authorizing request may have used
(`authorizationAttempts`), and the native route must call
`markEnrollmentAuthorizationAttempt` and see it succeed **before** sending any
request that may authorize the key. If the mark fails, the request is not sent.
Acknowledgment and local completion then require receipts only for marked keys
(`enrollmentSessionKeysRequiringRevocation`).

What counts as authorizing is decided fail-closed: only an explicit list of
requests known not to authorize (`auth.sendCode`, `auth.resendCode`,
`auth.cancelCode`, configuration/language lookups) may be sent unmarked;
everything else is marked first. `auth.exportLoginToken` must be marked: with
QR login the server authorizes the key when another device scans the code,
with no further request from this one.

Marking needs the open flow's permit, ticket and an already-bound key; it is
refused after the cleanup claim (the flow is over, so nothing may be sent), and
a refusal invalidates the flow's ticket like a refused binding. A repeated mark
is validated without a write. Tracking starts with a ledger's first bound key
and upgrades the payload to version 6; a ledger that already held keys without
tracking (versions 4–5) keeps requiring every bound key, because it cannot tell
which ones signed in. Marks must be bound keys of unique datacenters and need
version 6; anything else is corrupt.

Verification: six Core regressions, real red 13 failures; then 177 Mac / 179
hosted Core and 77 bridge cases passed (one bridge case completes a flow whose
two keys were never marked). Evidence:
`build-input/dual-pin-stage0/authorization-attempts-20261010/`.

### Server behaviour for a never-authorized key (measured 2026-10-11)

Probe against Telegram **test** DC2 (`149.154.167.40:443`, dc 10002, test RSA
key), using the vendored engine's `mtproto_core` and this build's api id: a
fresh permanent key (no PFS, no account) sent `help.getNearestDc` and then
`auth.logOut`. Three runs, three fresh keys: every `auth.logOut` returned
`auth.loggedOut` (`0xc3a2835f`, flags 0), never `401 AUTH_KEY_UNREGISTERED`.
So the server confirms a logout for a key that was never authorized; a
receipt for such a key can be obtained, and a success never proves that a
session existed, only that none remains on that key. Not measured: the same
over a PFS temporary key bound to a never-authorized permanent key, and
whether a main-DC logout revokes authorizations imported on other
datacenters (needs a signed-in test account). The probe binary was a
temporary Bazel target, removed afterwards; source, digest and logs are in
`build-input/dual-pin-stage0/logout-probe-20261011/`.

Consequence for marking: marking a key too early costs a logout of that key,
which the server confirms, as long as the native transport can still reach it.
It cannot for a key that is no longer the account's main key (the old
datacenter after `PHONE_MIGRATE`), so marks must not precede a migration.

## Local completion

`AccountEnrollmentBridge.completeProvisionalCleanup` runs after the scoped
logouts. In one AccountManager transaction it reads the required and confirmed
keys (each read validates the owner) and returns `.awaitingRevocation`, changing
nothing, while any key an authorizing request may have used lacks a receipt. Otherwise, under the cleanup read
gate, it requires detached metadata with the owned environment and removes the
owned raw record if one was promoted, exactly as upstream logout does
(`updateRecord { nil }`). Unrelated records and a newer current auth are kept.

Acknowledgment happens only in a later transaction that sees the removal
committed: it rechecks detachment and record absence under the read gate, then
acknowledges outside it (Core rechecks every receipt under its write lock). A
crash in between leaves an owned ledger with an absent record, which a retry
completes; the reverse order could drop the ledger while the record survived.
A resolved owner cannot complete again.

The account directory is not deleted here. Acknowledgment releases it to the
gated background cleanup (`withUnownedAccountDirectory` now admits the ID),
which removes it on its next scan of the account records, at the latest on the
next launch. Meanwhile the exclusive `mkdir` reservation keeps a new enrollment
from adopting it. The native owning job must release its provisional account
object (and so its open Postbox) before calling completion.

Six regressions: the real red ran 76 hosted cases with 27 expected failures,
zero unexpected errors, against a refusing stub; green passed all 76 with exit
0. One case fails each vault key load in turn and requires that a failure
between removal and acknowledgment was actually exercised and then retried.
Evidence: `build-input/dual-pin-stage0/local-completion-20261010/`.

## Cleanup job

`AccountEnrollmentBridge.runProvisionalCleanup` composes the boundaries above
for an already-claimed owner: detach the owned auth, then revoke, one at a
time, each key that an authorizing request may have used and that has no
receipt yet, then complete locally. The revocation is injected and trusted for
nothing: after it finishes, whatever it emitted, the job asks Core whether the
key's receipt exists. A missing receipt (an empty, failed or lying attempt)
stops the job with `.retryLater`, retaining the auth detachment, record, ledger
and directory; the next key is not tried until the previous one is confirmed.
A retry revokes only keys still unconfirmed. Keys never marked as attempted are
never sent a logout. A foreign or Share coordinator gets `.unavailable` before
anything is detached or revoked. The caller claims first and decides when to
retry; the job does not poll.

The native caller still has to supply the revocation (the scoped transport
covers the original main key only; any other required key returns no receipt
and keeps the owner) and to release its provisional account object before
completion. Six regressions: the real red ran 83 hosted cases with 14
expected failures against a refusing stub; green passed all 83. Evidence:
`build-input/dual-pin-stage0/cleanup-job-20261010/`.

## Startup recovery

`recoverProvisionalCleanup` runs once per launch from
`SharedAccountContext.configureModeAccountAccess`, main app only, right after
the directory gate is configured and off the main queue. At that point this
process cannot have started an enrollment, so a pending owner belongs to a dead
flow and claiming it is not polling an active one. No owner: nothing happens.
Otherwise it claims and runs the cleanup job once; `.retryLater` and
`.unavailable` keep everything for the next launch. Only the result enum is
logged.

`nativeRevocation` opens the provisional account from its directory with
`accountWithId(supplementary: true)` (its metadata is detached by then), and
sends the scoped logout only when the account's current original main key is
the key being revoked; for any other key nothing is sent, no receipt appears
and the owner is kept. The account object lives only for that attempt. The
native part compiles in the full app build; it has no offline test, because it
needs a real `AccountResult`.

Three recovery regressions (no owner, a dead flow completed and enrollment
freed again, Share refused). The first red invocation crashed in the fixture,
not the code: the no-owner case removed the temporary directory before
AccountManager finished initializing (Postbox disk I/O assertion, XCTest
relaunch); the fixture now waits, and the complete red ran 86 cases with six
expected failures. Evidence: `build-input/dual-pin-stage0/startup-recovery-20261010/`.

## Native integration still pending

`AccessModeAccountBridge` now implements the metadata-creation boundary in an
isolated module. It refuses an existing auth flow, validates the current Core
ticket, allocates a new raw auth record, rejects any existing raw-record ID
collision, and persists the exact environment binding inside the AccountManager
transaction callback before metadata synchronization or record-view publication.
Failure removes only the matching auth it just created, before publication.

A new raw ID must also be new on disk. Before binding, the bridge exclusively
creates that ID's canonical `account-<id>` directory beside `accounts-metadata`
with `mkdir`, which fails for any existing entry, including a symlink or a
dangling one. An orphaned directory (data without a metadata record) would
otherwise hand its existing Postbox and keys to the supposedly new provisional
session. Refusal removes the just-created auth and cancels the flow without a
cleanup ledger entry; the orphan is left untouched and a later attempt
allocates another ID. Rollback after the reservation uses `rmdir`, which removes
only a still-empty directory. A forced-collision regression covers a populated
directory, a symlink to another directory and a dangling symlink.

Each creation signal is single-use, including after cleanup or cancellation.
AccountManager's own queued transaction returns `EmptyDisposable`; subscription
disposal alone does not cancel its callback. The bridge checks a separate atomic
cancellation flag before Core enrollment, after enrollment and after binding.
Cancellation during binding rolls back the unpublished auth while retaining any
durable cleanup ownership. A later cancellation, after the last check or after
metadata commit, still requires native reconciliation of that exact owner; this
is not an absolute guarantee that subscription disposal undoes a commit.

`detachAuthForCleanup` runs an idempotent AccountManager transaction after the
durable cleanup claim. It validates the current claim under the Core read gate
before touching metadata, removes only the matching raw auth entry with the
same unambiguous environment, and leaves a replacement auth intact. Missing
owned auth is already detached. Its result proves only that auth-entry boundary:
an already promoted record and the encrypted ownership ledger remain unchanged.
It does not delete account data, revoke a server session or acknowledge cleanup.
This submitted cleanup may drain even after its observer is disposed; each
execution still validates the current owner inside the metadata callback.

`revokeProvisionalSession` is an unconnected Network adapter. It checks the
account's exact signed ID/environment, its directory under the supplied actual
AccountManager root, the current claimed Core owner and prior auth detachment.
The request is single-use, bounded to 15 seconds, and stops the owned service
tasks without automatic flood waiting. Empty responses, timeout, cancellation
and stale result ownership cannot mint its non-Codable ephemeral proof. No
metadata record deletion or ledger acknowledgment occurs at this boundary.

Transports default to refusing original-session evidence. The native adapter
now uses `ScopedEnrollmentLogoutTransport`: it captures the original main
datacenter/digest once, requires all persisted datacenter keys plus the current
root/owner/environment and MtProtoKit engine, then passes that immutable scope
to `Network.request`. A changed main key/datacenter needs an explicit new
adapter; a retained request cannot silently rebase. Task stopping is followed
by another fresh validation. The actual MTProto preparation boundary separately
checks the selected permanent key or recorded PFS provenance on every retry.

The native adapter accepts only a successful scoped `auth.LoggedOut`. All its
RPC errors remain unconfirmed, including documented inactive-key errors: a
temporary-key error cannot prove the permanent session is inactive. Internal
fake transports simulate a current original session and classify the exact
documented inactive authorization errors, with a separate original-binding
requirement for those errors. They are not real server evidence. A newly
generated unregistered key after database/key loss does not prove the previous
session was revoked. Every accepted simulated response also revalidates current
session evidence, detached metadata, environment and durable ownership in a
fresh AccountManager transaction before minting the ephemeral proof.

The module does not expose authorization UI and is not connected to a native
root/session cleanup adapter yet. A real caller must prove its originating root,
actual AccountManager/context and confirmed self identity separately.
Acknowledgment is valid only after the native adapter has proved exact cleanup
and authoritative record absence. Component tests simulate this boundary with
fixtures that have no actual Telegram session; they do not prove server logout.

`bindOriginalSessionKey` reads the existing `.persistent` key from the supplied
actual `UnauthorizedAccount.network.context`; it never asks the engine to create
a key. Only a positive Int32 datacenter, a full 256-byte permanent key and the
permanent lifetime marker are accepted. SHA-256 is the only value persisted in
Core. A temporary key or absent/malformed key returns a neutral failure.

Before persistence, the bridge checks the account directory beneath the supplied
`accounts-metadata` root, the exact still-current raw auth ID, absence of a
promoted record, unambiguous environment and the current Core permit/ticket.
The request is single-use. Queued disposal prevents writes; disposal during
persistence retains any committed binding while cancelling completion authority.
A key change detected at write completion locks access and retains the saved
original. No auth record or server session is deleted by this operation.

This Bool reports durable evidence only. It grants no authorization, unlock or
logout proof. Native caller/root integration and enrollment datacenter-migration
handling remain pending; request-level PFS provenance is implemented. The
future caller must repeat ownership and key validation at actual submission;
an earlier successful binding cannot authorize a later request on its own.

`reconcileOriginalSessionKeys` reads the actual native account after restart and
requires every saved datacenter fingerprint to match. The account's current
datacenter must have a saved binding, and its exact directory, detached metadata,
environment and current cleanup ticket must still agree. Old unbound ledgers,
upgrading accounts, missing keys and replacement keys refuse. This operation
does not rewrite the encrypted vault, create a key or submit a network request.
MTContext reads occur outside the Core vault lock to avoid lock inversion.

The [Telegram PFS specification](https://core.telegram.org/api/pfs) binds each
temporary key to a permanent key. A current context snapshot does not establish
which cached key a delayed request actually uses. The transport boundary
checks the selected key at every preparation, including retries, and retains
successful temporary-key binding provenance. The verified MtProtoKit component
now does this; [protected transport](PROTECTED_SESSION_TRANSPORT.md) records its
boundary. Higher-level request options now also pass isolated checks and full
application compilation. The native account adapter now forwards the protected
scope. Its owning job and configured authorization routes remain unconnected;
no server/local completion or physical-device behavior is inferred.

Before exposing authorization:

1. Validate a current role/root and persist the enrollment origin.
2. Refuse an existing auth flow, raw-record collision or existing account
   directory for the new ID. Inside AccountManager's
   transaction, create an auth record and persist its exact Core binding before
   returning; publication/file synchronization occurs after that callback.
3. On bind failure, cancel only that newly created matching auth record before
   transaction commit; do not replace or delete another flow's record.
4. Pass only current-role phone metadata to AuthorizationUI. Guard authorization
   promotion and revalidate before account publication. The common metadata
   helper now refuses missing/stale/different current auth IDs, an already
   existing record, and mismatched/ambiguous environment attributes before any
   mutation. Its seven existing call references in `Authorization.swift` and
   `Account/Account.swift` share that helper. This guard does not authenticate
   the confirmed self, current root or role. Upstream callers still write their
   own Postbox authorization state and may report completion independently;
   native admission must separately refuse those stale results.
5. On cancel, lock, failed completion or restart, claim exact cleanup before
   side effects; stop the owned pending flow, clean/revoke only its provisional
   session, verify absence, then acknowledge. Do not claim an active enrollment
   as routine background polling. Failure keeps quarantine and retry evidence.
   Upstream `Account/AccountManager.swift.cleanupAccount` catches a failed
   `auth.logOut` and still removes metadata; its completion alone is therefore
   not proof of successful server-session revocation. The owned adapter must
   preserve this distinction rather than acknowledge cleanup on that signal.

Native enrollment remains closed. This checkpoint does not establish safe
authorization UI, server-session cleanup, notification suppression, B root
admission, or full stage-3 acceptance.

## Fresh component verification

Fresh continuation checks passed 156 Mac cases and 158 hosted iOS Core cases,
including the original-session-binding and version-4 recovery checks. The legacy
migration suite passed 29 hosted cases. Expanded metadata/native-binding bridge
passed 41 hosted cases with zero failures, exit 0, 60.556 seconds overall / 11.679 test
seconds, including nine creation/cancellation, seven common-promotion and eight
auth-detachment and nine scoped logout/response cases.
Eight additional binding cases verify actual `MTDatacenterAuthInfo` parsing,
an independent SHA-256 vector, durable publication/reopen, metadata/path refusal,
stale/Share/replacement denial and queued/in-flight disposal or key change.
They use unique temporary fixture directories, no real account session
or network authorization. The independent-reader case verifies actual atomic
AccountManager metadata and the reopened encrypted vault; the publication
observer reads exact durable ownership before the raw auth record is emitted.

Current commands, source/tool digests and copied XCTest results are retained in
`build-input/dual-pin-stage0/chat-continuation-20261010/`. These component checks
do not prove that the native Telegram transport has bound an actual key; its
public RPC-error handling still retains unconfirmed ownership.

The same Core sources passed a full own-bundle simulator application build,
exit 0, 275.189 seconds, 538 actions. Retained artifact:
`build-input/dual-pin-stage0/chat-continuation-20261010/app-builds/20261010T062600Z/Telegram.ipa`,
SHA-256 `591ed42ac7e28897f42898bc5a1a6102998b6717da74bef7f23e421c63273630`.
This checkpoint adds no configured authorization route or native cleanup job;
it does not establish a new simulator launch or physical-device/server behavior.

Native-binding red ran 39 cases with eight expected failures and zero unexpected
XCTest errors. Expanded 41-case green then passed. The unchanged verified bridge
sources passed full app compilation, exit 0, 37.915 seconds, 52 actions; artifact
`build-input/dual-pin-stage0/native-session-binding-20261010/app-builds/20261010T064641Z/Telegram.ipa`,
SHA-256 `b976b0548245eaddfbe5c9386120a23e278fc8815dfcf8ecf26a0c556d7471e4`.
Commands and retained test/build results are in that ignored stage-0 directory.

Restart/response reconciliation added six regressions. The real red executed 47
cases with five expected failures and zero unexpected XCTest errors, then the
upstream runner timed out after completed assertions. The initial fixture compile
failure executed no tests; its stale prior test log is explicitly annotated.
Fresh green passed all 47 cases, exit 0, 67.192 seconds overall / 14.276 test
seconds. Full application compilation passed exit 0, 39.369 seconds, 51 actions;
artifact `build-input/dual-pin-stage0/native-session-reconciliation-20261010/app-builds/20261010T070847Z/Telegram.ipa`,
609,559,497 bytes, SHA-256
`3048f0bb3a0599a773ad13916df4cf0218f9898c5c1597567314db200682bc9e`.
Exact commands, fresh results and source digests are retained in that stage-0
directory. No native cleanup job, configured-account acceptance, simulator
launch or physical-device/server behavior is inferred from these checks.

Replay and cancellation regressions were observed failing before the correction:
seven-case replay red had three expected failures; nine-case cancellation red
had seven expected failures and zero unexpected XCTest errors. That red runner
timed out after the actual tests completed; both facts remain in the logs. Green
finished successfully. Common promotion red ran 14 cases with 21 expected
failures; its expanded red ran 16 with 27 expected failures. Both had zero
unexpected XCTest errors and later hit the upstream result-export `_values`
KeyError. All 16 corrected cases then passed with exit 0. The cleanup read gate
red ran five Mac cases with seven expected failures; its green and full 149-case
Mac/151-case hosted checks passed. Auth-detachment red ran 22 cases with six
expected failures, zero unexpected errors; 22-case green and expanded 24-case
checks then passed with exit 0. Retained evidence is under ignored
`build-input/dual-pin-stage3/account-bridge-creation-*`.

Read-gate evidence is under `cleanup-read-gate-*`, and auth-detachment evidence
is under `auth-detachment-*` in the same ignored directory. No real account
session was authorized or revoked by these tests. The official
[auth.logOut reference](https://core.telegram.org/method/auth.logOut) was refreshed
on 2026-10-10: the method returns `auth.LoggedOut`. Our future native job must
keep ownership/retry evidence on a network failure; a generic upstream cleanup
completion that swallowed that failure is insufficient.

Native scoped transport red ran 63 hosted cases with 26 expected failures,
zero unexpected errors, exit 1; green passed all 63 with exit 0. Expanded public
adapter checks passed 65 cases, zero failures, exit 0, 68.510 seconds overall /
21.986 test seconds. They use real AccountManager/Core and the actual scoped
transport, with fake key/RPC sources and no live account or network. Full own
app compilation passed exit 0, 45.392 Bazel seconds, 51 actions; source hashes
match. Artifact under `build-input/dual-pin-stage0/native-protected-logout-20261010/`:
`app-builds/20261010T091607Z/Telegram.ipa`, 609,653,849 bytes, SHA-256
`bbf0e7f5d38247b828f1f432bee633d3707bd60afc77de03846bbe0a67ff2cd0`.
Durable server-confirmation persistence, exact local completion and the owning
native job remain required before exposing configured enrollment.

Hosted metadata command (run serially with other Bazel/build invocations):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -u build-system/Make/Make.py \
  --bazel '/Users/negrfors/Desktop/tg fork/build-input/dual-pin-stage0/bazel-resource-limited' \
  --overrideXcodeVersion --cacheDir /tmp/tg-dual-pin-bazel-cache test \
  --configurationPath build-system/appstore-configuration.json \
  --codesigningInformationPath build-system/fake-codesigning \
  --target //submodules/AccessModeAccountBridge:AccessModeAccountBridgeTests
```
