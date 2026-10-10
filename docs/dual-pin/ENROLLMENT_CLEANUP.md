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

## Storage version and failures

First provisional binding upgrades the vault payload to version 3. Existing
ordinary version-1/2 vaults remain readable. Owner-PIN journal work preserves the
higher version, including after recovery. Earlier fork builds reject version 3
instead of ignoring its cleanup ownership. The configuration and encrypted
envelope versions are independent and remain unchanged.

A new-schema bound enrollment requires its matching cleanup ledger. Missing,
aliased, inconsistent or downgraded ownership is corrupt and refuses access;
it cannot trigger fresh setup. Failed claim/ack writes preserve the exact prior
encrypted bytes for retry. A record already accepted into configuration can
never become a cleanup target. Old unexposed version-1/2 pending enrollment data
does not create new cleanup authority; unknown raw records must be quarantined,
never guessed or deleted.

## Native integration still pending

The component has no connected AccountManager/session cleanup adapter yet.
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
   promotion against stale/missing/different current auth IDs, and revalidate
   before account publication. The upstream common promotion helper currently
   calls generic removeAuth and has not yet received these guards.
5. On cancel, lock, failed completion or restart, claim exact cleanup before
   side effects; stop the owned pending flow, clean/revoke only its provisional
   session, verify absence, then acknowledge. Do not claim an active enrollment
   as routine background polling. Failure keeps quarantine and retry evidence.

Native enrollment remains closed. This checkpoint does not establish safe
authorization UI, server-session cleanup, notification suppression, B root
admission, or full stage-3 acceptance.
