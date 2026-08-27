# Getting a Developer ID — optional, and not what this project does

> **Multiemu ships unsigned.** It is MIT-licensed open source with no Apple
> Developer membership behind it, and `scripts/release.sh --unsigned` is the
> supported release path. Nothing below is required to build, run, fork or
> distribute Multiemu.
>
> This document is kept because the licence lets anyone make signed builds of
> their own — a company deploying it internally, say, or a fork that wants to
> hand users a DMG that opens without a right-click. If that is you, read on.
> Otherwise skip it; `docs/RELEASE.md` covers the path this project uses.

## What a Developer ID would buy

Signing removes the Gatekeeper warning a user sees on first launch. That is the
whole of it. Three steps need Apple credentials, and none can be faked:

| Step | Needs |
| --- | --- |
| Signing the app and the disk image | **Developer ID Application** certificate |
| Notarizing both | Notary credentials (Apple Account or API key) |
| Passing Gatekeeper on another Mac | Both of the above, plus stapling |

`security find-identity -v -p codesigning` returns **0 valid identities** on the
machine this was developed on. That is why the signed path refuses — and why
`--unsigned` exists as a first-class mode rather than a fallback.

## The good news first: no special entitlement request

This project signs three bundles, with these entitlements:

| Bundle | Entitlement | Needs Apple's approval? |
| --- | --- | --- |
| `MultiemuQEMUHelper` | `com.apple.security.hypervisor` | **No** |
| `MultiemuVZHelper` | `com.apple.security.virtualization` | **No** |
| `Multiemu.app` | `com.apple.security.files.user-selected.read-write` | **No** |

All three are available to any Developer ID account without a request. The
virtualization entitlements that *do* need Apple to grant them are the ones this
project does not use — bridged networking (`com.apple.vm.networking`) and direct
device access. Guest networking here is QEMU's user-mode stack, which needs no
privileges at all.

So the only thing standing between the rehearsal and a real release is a paid
membership and a certificate.

## Step 1 — Enrol in the Apple Developer Program

Go to <https://developer.apple.com/programs/enroll/>.

- You need an Apple Account with **two-factor authentication** switched on.
  Enrolment will refuse without it.
- Choose **Individual/Sole Proprietor** or **Organization**:
  - *Individual* is much faster. Your legal name becomes the certificate name,
    and therefore the name users see in Gatekeeper's dialog.
  - *Organization* shows the company name instead, but requires a **D-U-N-S
    number** for the legal entity and someone with authority to bind it. Getting
    a D-U-N-S number is itself a separate application and can add days.
- Membership is **$99 USD per year** at the time of writing.
- Approval is usually a day or two for an individual; organizations take longer
  because the entity is verified.

A free Apple Developer account is not enough. Free accounts can sign for local
development only, and cannot create a Developer ID certificate at all.

## Step 2 — Create the Developer ID Application certificate

Only the **Account Holder** can create Developer ID certificates. If someone else
owns the membership, they have to do this part or export the identity to you.

### With Xcode (easiest)

1. Xcode ▸ Settings ▸ **Accounts**
2. Add the Apple Account, select the team, **Manage Certificates…**
3. **+** ▸ **Developer ID Application**

Xcode creates the private key in your login keychain and downloads the matching
certificate.

### Without Xcode (or if you prefer to see each part)

1. **Keychain Access** ▸ menu **Certificate Assistant** ▸ *Request a Certificate
   From a Certificate Authority…*
   - Enter your email and name, choose **Saved to disk**, and tick *Let me
     specify key pair information* (2048-bit RSA).
   - This produces a `.certSigningRequest` and, importantly, leaves the **private
     key** in your keychain.
2. <https://developer.apple.com/account/resources/certificates/list> ▸ **+**
3. Choose **Developer ID Application**, upload the CSR, download the `.cer`.
4. Double-click the `.cer` to install it into the login keychain, beside the key.

You do **not** need a provisioning profile. Those are for App Store and
development builds; Developer ID distribution does not use them.

### Back the identity up immediately

In Keychain Access, select the certificate *and* its private key, right-click ▸
**Export 2 items…** ▸ save as `.p12` with a strong password. Keep it somewhere
that is not this repository and not a code host.

Losing the private key means you cannot ever re-sign as the same identity —
Apple can issue a new certificate, but it is a different key, and users see it as
a different developer. Apple also caps how many Developer ID Application
certificates an account may hold, so churning through them is not free.

## Step 3 — Set up notary credentials

Notarization is a separate credential from signing. Two ways:

### App-specific password (simplest)

1. <https://account.apple.com> ▸ **Sign-In and Security** ▸ **App-Specific
   Passwords** ▸ **+**, name it something like `multiemu-notary`.
2. Find your **Team ID**: <https://developer.apple.com/account> ▸ Membership
   details. It is the ten-character string like `A1B2C3D4E5`.
3. Store it in the keychain once:

```bash
xcrun notarytool store-credentials multiemu-notary --apple-id you@example.com --team-id A1B2C3D4E5 --password abcd-efgh-ijkl-mnop
```

### App Store Connect API key (better if this ever runs in CI)

1. <https://appstoreconnect.apple.com/access/integrations/api> ▸ generate a key
   with the **Developer** role. You get an Issuer ID, a Key ID, and a `.p8` file
   that downloads **once**.
2. Store it:

```bash
xcrun notarytool store-credentials multiemu-notary --key AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer 11111111-2222-3333-4444-555555555555
```

An API key has no password to rotate and is not tied to a person, which matters
if the release ever stops being run from your Mac.

## Step 4 — Point this project at them

```bash
export MULTIEMU_SIGN_IDENTITY="Developer ID Application: Your Name (A1B2C3D4E5)"
```

`MULTIEMU_NOTARY_PROFILE` overrides the profile name if you did not call it
`multiemu-notary`. Neither belongs in this repository, and neither should be
committed anywhere — the brief is explicit about that, and so is
`docs/RELEASE.md`.

## Step 5 — Check, then release

```bash
security find-identity -v -p codesigning
```

You want a line reading `Developer ID Application: Your Name (A1B2C3D4E5)`.
Anything else — `Apple Development`, `Mac Developer` — is the wrong kind of
certificate and will notarize-reject.

Then rehearse once more, which now reports the credentials as found rather than
missing:

```bash
scripts/release.sh --rehearsal
```

And when it looks right:

```bash
scripts/release.sh
```

## What to expect the first time

- **Notarization takes minutes, not seconds.** `notarytool submit --wait` blocks
  until Apple answers. A few minutes is normal.
- **A rejection comes with a log.** `xcrun notarytool log <submission-id>
  --keychain-profile multiemu-notary` prints exactly which binary failed and
  why. The usual first-time causes are a bundled binary that was not signed, a
  missing hardened runtime, or a missing secure timestamp. This pipeline already
  passes `--options runtime --timestamp` and signs inside-out, so those three
  should not bite.
- **Signing order matters, and this project learned it the hard way.** Adding
  licence files to an already-signed bundle broke its seal, and nothing in the
  build said so — the app had verified moments earlier. Licences are now
  collected before `codesign` runs. If you ever add a file to the bundle, add it
  before signing.
- **Verify on a Mac that has never seen the source.** Gatekeeper treats a build
  from your own machine differently. The real test is a second Mac, or at least
  a fresh user account, opening the DMG downloaded rather than copied.

## What still cannot be checked here

Even with credentials, one criterion needs hardware this project does not have:
installation on a clean Mac. That needs a notarized DMG *and* a second machine.
It is the last thing in the pipeline that a single developer machine cannot
answer for itself.
