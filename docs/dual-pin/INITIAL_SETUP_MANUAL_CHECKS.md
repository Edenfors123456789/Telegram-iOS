# Initial setup and partial-commit checks

These checks are pending. They do not replace the full release/iPhone checklist.
The initial native handler is available from local PIN settings only on an
ordinary unconfigured owner root with a complete confirmed account pool. Its
component tests and successful compilation do not complete these manual steps.

Use only a separate test installation, an accessible signing team and explicitly
chosen test accounts. Do not copy IMO sessions, reset real Keychain/account stores,
send real messages or alter the production fleet to run these checks.

## Account choice and owner proof

- Start with no Dual PIN configuration and a complete authorized account pool.
  Select the shared primary. Existing additional accounts initially belong to A.
- Check different accounts with identical display names; a displayed name must
  never determine account identity. Verify the chosen actual self user and record.
- Pending login, unloaded self peer, missing metadata, duplicate identity or an
  invalid role quota must prevent initialization without deleting any account.
- Try no existing local PIN, a four-digit PIN, a six-digit PIN and an alphanumeric
  PIN. An existing PIN requires fresh PIN-authenticated owner proof, never biometrics
  or a borrowed settings session. Wrong owner input must not replace credentials.
- Verify both new PINs have exactly six ASCII digits, independent confirmations
  and distinct values. Check pasted Unicode digits and mismatched confirmations.
- On submission, all entered values/account-choice handlers must clear before
  worker execution. Completion must show a fresh stock lock, never automatic A/B.

## Lifecycle and stale UI

- Record actual frames during submission, inactive transition and return. The
  native cover must precede root/modal/keyboard teardown and system snapshots.
- Keep delayed account-info, root-readiness, search and native-dismissal callbacks
  pending; complete them during setup and after a newer lock. Old callbacks must
  not publish a raw root or remove a newer cover.
- Background immediately before owner verification, during legacy rewrap, after
  AccountManager acknowledgment and after the access file commit. Return and enter
  a fresh PIN; previous navigation/results must never be restored as authority.
- Confirm a partial four-to-six-digit owner replacement discards the old input
  controller and requests the newly acknowledged six-digit PIN A.

## Durable outcome and retry

Use controlled fixture fault injection, never corruption of a real installation.

- Fail before the first legacy save: old owner PIN and protected resource key
  remain usable; fresh owner-authenticated retry is possible.
- Fail after owner rewrap/AccountManager acknowledgment but before Core commit:
  the already saved new A code becomes the known owner retry code; the original
  protected resource key remains identical. No old/unsecured challenge fallback.
- Add pending authorization or change the account pool after owner rewrap. The
  new owner reference must still be acknowledged; Core publication must refuse.
- Fail biometric cleanup, protected-resource enabling, encrypted file commit or
  Keychain presence-witness update. Inspect the actual durable state after each
  outcome; an exception alone does not establish that configuration is absent.
- A readable configured outcome requires fresh mode PIN authentication. A corrupt,
  missing-after-commit or unavailable outcome denies raw account/UI publication.
- Only a successfully confirmed never-configured/absent outcome can restore the
  matching temporary account gate, behind a fresh legacy owner PIN cover. A late,
  foreign or repeated callback cannot clear required mode access.
- Repeat across process interruption, device reboot, offline/network change and
  protected-data unavailability. Do not infer these results from simulator launch.

## Current acceptance limit

B native root admission remains explicitly denied until history filtering and
notification/external-surface restrictions have been verified. Message/VoIP push,
badges and packaged extensions are still stage-5 work. This intermediate build
must not be installed or described as a privacy-ready Dual PIN client.
