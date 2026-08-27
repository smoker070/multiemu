# Releasing Multiemu

Multiemu is MIT-licensed open source and ships **unsigned**. There is no Apple
Developer membership behind it, and notarization is a step this project does not
take rather than one it cannot.

```bash
scripts/release.sh --unsigned      # what this project ships
scripts/release.sh --rehearsal     # exercise everything that needs no credentials
scripts/release.sh                 # signed and notarized; refuses without a Developer ID
```

Each mode refuses to be mistaken for another. `--unsigned` names its output
`Multiemu-<version>-unsigned.dmg`, because a file called `Multiemu-0.9.0.dmg`
that Gatekeeper refuses is indistinguishable, once downloaded, from a signed one
that broke.

## What a user has to do with an unsigned build

Gatekeeper will refuse it on first launch. That is correct and expected. After
dragging the app out of the disk image, either:

```bash
xattr -d com.apple.quarantine /Applications/Multiemu.app
```

or right-click the app and choose **Open**, which offers the same override
through the interface. Anyone who would rather do neither can build from source
— `scripts/build-app.sh` needs no credentials at all.

## What the pipeline does

| Step | What it does | Needs credentials |
| --- | --- | --- |
| 1. Preflight | Checks tooling, finds the signing identity and notary profile | — |
| 2. Tests | Runs the full suite | — |
| 3. Build | Assembles the app, collects licences, signs inside-out | Developer ID |
| 4. Signature | Reports identifier, format, entitlements, hardened runtime | — |
| 5. Notarize the app | Submits, waits, staples, validates | Notary profile |
| 6. Disk image | Builds a compressed image, mounts it, verifies the app inside | — |
| 7. Sign the image | Developer ID with a secure timestamp | Developer ID |
| 8. Notarize the image | Submits, waits, staples, validates | Notary profile |
| 9. Assess | `spctl` on both, exactly as Gatekeeper would | — |

A step that cannot run is **named in the summary**, not skipped quietly. A run
without a Developer ID is refused outright unless `--rehearsal` is passed:
producing an unsigned DMG would look like a finished release and behave like a
broken one.

## Credentials

Never in this repository, and never in an environment variable committed
anywhere. Store them once in the keychain:

```bash
xcrun notarytool store-credentials multiemu-notary --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
```

Then export the identity:

```bash
export MULTIEMU_SIGN_IDENTITY="Developer ID Application: … (TEAMID)"
```

`MULTIEMU_NOTARY_PROFILE` overrides the profile name if you use another.

## Shipping QEMU: the obligation, and how the pipeline enforces it

QEMU is **GPL-2.0-only**. Multiemu never links it — it is a separate executable
spawned as a child process and driven over a socket — but *distributing the
binary* still obliges us to provide the corresponding source for that exact
build, with its licence text.

`scripts/collect-licenses.sh` **refuses** to prepare a bundle that contains QEMU
binaries without a source tree, and the refusal is an error, not a warning:

```
REFUSED: this bundle contains QEMU binaries in Contents/Helpers, but no QEMU
source tree was given.
```

A release that bundles helpers therefore runs:

```bash
scripts/build-qemu.sh                                   # build from pinned source
export MULTIEMU_SOURCE_URL="https://…/qemu-source"      # where the source is published
scripts/release.sh --with-helpers --qemu-source <dir>
```

which writes into `Multiemu.app/Contents/Resources/licenses/qemu/`:

- `COPYING` — the licence text, copied from the source that produced the binary
- `SOURCE-VERSION.txt` — version, commit and describe of that exact tree
- `WRITTEN-OFFER.txt` — the offer, valid three years, naming where the source is

**Licences are collected before signing.** Adding anything to `Contents/` after
`codesign` breaks the bundle's seal, and the failure does not surface until
something verifies it later — which is precisely how it was found here, by the
disk-image step reporting *a sealed resource is missing or invalid*.

The same obligation applies to any Linux kernel shipped with a guest image.

## Update strategy

**Chosen: a signed manifest check that notifies, and never installs.**

The app fetches a small JSON manifest over HTTPS, verifies its signature against
a public key compiled into the app, and — if a newer version exists — tells the
user and opens the download page. It never downloads or replaces anything
itself.

Why not Sparkle, which is what most directly-distributed Mac apps use:

- It is a third-party dependency, and this project has none by policy. That
  policy is not squeamishness: every dependency is something whose licence,
  provenance and update cadence has to be tracked for a *closed-source,
  notarized* product.
- An auto-updater is a code-execution path that replaces the application
  binary. This application already spawns helper processes and, in the shipping
  configuration, carries a hypervisor entitlement. Adding a self-replacing
  install path to that is a larger security surface than the convenience earns.

Consequences, stated plainly: users update by downloading a new DMG, so uptake
will be slower than an auto-updater's, and a security fix reaches people only as
fast as they act on the notice. That trade is accepted for now and should be
revisited if a security fix ever needs to reach users quickly.

The check must be disclosed on first run and switchable off. It is **not
implemented** — this milestone chose the strategy, which is what its criteria
ask for.

## What a release still cannot claim here

| | |
| --- | --- |
| Developer ID signing | No identity is available to this project |
| Hardened runtime | Applied only for a real identity, so never exercised |
| Notarization and stapling | No notary credentials |
| `spctl` acceptance | **Rejects** today, which is the correct result for an ad-hoc build and is what proves the check discriminates |
| Clean-Mac installation | Needs a notarized DMG and a second Mac |

Everything above the credential boundary is exercised by `--rehearsal` on every
run, so the untested part is the credential use itself, not the pipeline around
it.
