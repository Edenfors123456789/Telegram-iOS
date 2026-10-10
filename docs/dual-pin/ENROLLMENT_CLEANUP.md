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

This storage boundary accepts a digest from a trusted adapter. Native extraction
of the actual persistent key, binding before authorization, reconciliation after
restart and verifying which key a logout RPC used remain pending. The Core
component alone does not establish original-session provenance or server logout.

A new-schema bound enrollment requires its matching cleanup ledger. Missing,
aliased, inconsistent or downgraded ownership is corrupt and refuses access;
it cannot trigger fresh setup. Failed claim/ack writes preserve the exact prior
encrypted bytes for retry. A record already accepted into configuration can
never become a cleanup target. Old unexposed version-1/2 pending enrollment data
does not create new cleanup authority; unknown raw records must be quarantined,
never guessed or deleted.

## Native integration still pending

`AccessModeAccountBridge` now implements the metadata-creation boundary in an
isolated module. It refuses an existing auth flow, validates the current Core
ticket, allocates a new raw auth record, rejects any existing raw-record ID
collision, and persists the exact environment binding inside the AccountManager
transaction callback before metadata synchronization or record-view publication.
Failure removes only the matching auth it just created, before publication.

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

The real transport confirms only successful `auth.LoggedOut`. Every real RPC
error remains unconfirmed. Internal tests classify the exact documented inactive
authorization errors, but applicability requires an original-credential binding;
the public transport has no such override. A newly generated unregistered key
after database/key loss does not prove the previous session was revoked.
Persistent original-key/restart reconciliation remains a prerequisite for native
cleanup admission. The internal fake transport is not real server evidence.

The module does not expose authorization UI and is not connected to a native
root/session cleanup adapter yet. A real caller must prove its originating root,
actual AccountManager/context and confirmed self identity separately.
Acknowledgment is valid only after the native adapter has proved exact cleanup
and authoritative record absence. Component tests simulate this boundary with
fixtures that have no actual Telegram session; they do not prove server logout.

Before exposing authorization:

1. Validate a current role/root and persist the enrollment origin.
2. Refuse an existing auth flow or raw-record collision. Inside AccountManager's
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
migration suite passed 29 hosted cases. Metadata bridge passed 33 hosted cases
with zero failures, exit 0, 54.137 seconds overall / 8.697 test
seconds, including nine creation/cancellation, seven common-promotion and eight
auth-detachment and nine scoped logout/response cases.
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

Hosted metadata command (run serially with other Bazel/build invocations):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -u build-system/Make/Make.py \
  --bazel '/Users/negrfors/Desktop/tg fork/build-input/dual-pin-stage0/bazel-resource-limited' \
  --overrideXcodeVersion --cacheDir /tmp/tg-dual-pin-bazel-cache test \
  --configurationPath build-system/appstore-configuration.json \
  --codesigningInformationPath build-system/fake-codesigning \
  --target //submodules/AccessModeAccountBridge:AccessModeAccountBridgeTests
```
