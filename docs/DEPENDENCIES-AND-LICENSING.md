# Dependencies and licensing map

**Multiemu is open source under the MIT licence** (see `LICENSE`). It is
distributed as source, and as an **unsigned** disk image built by
`scripts/release.sh --unsigned` — there is no Apple Developer membership behind
this project and no notarization, by choice rather than by obstacle.

This document is the gate. A dependency that is not listed here may not be added
to the product. Every entry states the license, whether the component is
*linked* or *spawned*, and what shipping it obliges us to do.

**What being open source changed, and what it did not.** An earlier version of
this file targeted a closed-source, Developer ID signed, notarized `.dmg`, and
several obligations below were written against that. Going MIT removes the
hardest question — whether a copyleft component could ever reach a proprietary
binary — because there is no proprietary binary. It removes none of the
obligations that attach to *shipping someone else's binary*:

| Still true | Now moot |
| --- | --- |
| Bundling QEMU binaries obliges us to ship QEMU's `COPYING` and corresponding source | Whether GPL code could "infect" a closed application |
| Shipping a guest kernel obliges the same for its source and `.config` | Whether Developer ID signing conflicts with GPL-2.0 anti-tivoization (it does not, and there is no signing) |
| Google's `platform-tools` `adb` may not be redistributed | — |
| Play Services and proprietary Google images stay out | — |

MIT is compatible with everything here: it imposes nothing on GPL code we spawn
but never link, and nothing stops a GPL-licensed fork.

> This is an engineering analysis, not legal advice. The GPL and AOSP
> obligations below are the ones that matter for a binary release; if you
> distribute one, satisfy them.

---

## 1. The rule that drives every decision

**Nothing under a copyleft license is ever linked into Multiemu's binaries.**
Copyleft components are shipped as *separate executables* that we spawn and talk
to over sockets, and we publish their corresponding source.

This is why the process topology in `BACKEND-EVALUATION.md` looks the way it
does. The isolation is a licensing requirement first and a crash-recovery
benefit second.

---

## 2. Host-side components

| Component | License | How we ship it | Obligation |
| --- | --- | --- | --- |
| **QEMU** (`qemu-system-aarch64`, `qemu-system-x86_64`, `qemu-img`) | **GPL-2.0-only** (with LGPL-2.1, BSD and MIT parts) | Separate executable inside `Multiemu.app/Contents/Helpers/`, spawned as a child process, controlled over a QMP UNIX socket. **Never linked.** | Publish the exact source tarball plus our build scripts and any patches, and include a written offer + `COPYING` in the app. The source must correspond to the binary we ship, per version. GPL-2.0 has no anti-tivoization clause, so Developer ID signing, the hardened runtime and notarization are all compatible. |
| **libslirp** (QEMU user-mode networking) | BSD-3-Clause | Inside the QEMU process. | Attribution only. |
| **gfxstream** (AOSP `hardware/google/gfxstream`) | **Apache-2.0** | Linked into our own renderer helper, or run as a `vhost-user-gpu` backend. | `NOTICE` retention. Safe for closed-source linking. |
| **virglrenderer** | MIT | Alternative renderer; linkable. | Attribution only. |
| **MoltenVK** | Apache-2.0 | Linked if the renderer needs Vulkan-on-Metal. | `NOTICE` retention. |
| **ADB client/server** built from AOSP `packages/modules/adb` | **Apache-2.0** | Built by us, shipped as a helper executable. | `NOTICE` retention. **This is why we do not ship Google's `adb` binary** — see §4. |
| **Apple Virtualization.framework / Hypervisor.framework / Metal / Network / os** | Apple system frameworks | Linked. | None. Entitlements apply — see §5. |
| **Sparkle** (if used for updates) | MIT | Linked. | Attribution. Alternative: our own updater, no dependency. Decision deferred to M21. |

### QEMU compliance checklist (must be true at every release)

- [ ] `vendor/qemu/VERSION` pins an exact upstream tag.
- [ ] `scripts/build-qemu.sh` reproduces the shipped binary from that tag.
- [ ] Any patch we apply lives in `vendor/qemu/patches/` and is published.
- [ ] The release publishes a source tarball for that exact build.
- [ ] `Multiemu.app/Contents/Resources/licenses/qemu/` contains `COPYING` and
      the written offer.
- [ ] The About window links to the source.
- [ ] The helper is signed with Developer ID **and** the hardened runtime **and**
      `com.apple.security.hypervisor`, and it notarizes.

---

## 3. Guest-side components (the Android image)

| Component | License | Obligation |
| --- | --- | --- |
| **AOSP platform** (framework, system, vendor, ART, bionic) | Apache-2.0 (with some BSD/MIT parts) | Redistributable. Must ship the aggregated `NOTICE` file, which Android's build system generates and Android itself displays under Settings → About → Legal information. |
| **Linux kernel** (Android Common Kernel / GKI) | **GPL-2.0-only** | Shipping a kernel binary obliges us to publish its corresponding source and `.config`. Same treatment as QEMU: pinned tag, published tree, written offer. |
| **Mesa guest drivers** (virtio-gpu / gfxstream Vulkan) | MIT | Attribution. |
| **`drm_hwcomposer`, `minigbm`** | Apache-2.0 / BSD-3-Clause | Attribution. |

### Explicitly out of scope for redistribution

These are **not** bundled, and Multiemu must never imply they are available:

- Google Play Store, Google Play Services, Google Mobile Services
- Google-distributed system images (`google_apis`, `google_apis_playstore`)
- Any binary obtained through the Android SDK Manager
- Proprietary vendor firmware or DRM modules (Widevine)
- Patented codecs whose hardware/software implementations require a license

A user may sideload whatever they choose onto their own virtual device. That is
their action, not a Multiemu feature, and the UI must not offer it as one.

---

## 4. Components that exist but may not be redistributed

| Component | Why not | What we do instead |
| --- | --- | --- |
| Google's `adb` binary from SDK platform-tools | Distributed under the Android SDK License Agreement, which does not grant redistribution | Build our own ADB from AOSP source (Apache-2.0). Note the distinction: **the source is Apache-2.0; the Google-built binary is not redistributable.** |
| Android Emulator (`emulator`) from the SDK | Android SDK License Agreement | Development-time reference oracle only, installed by the developer. Never bundled, never invoked by the shipping app. |
| Google-built Cuttlefish images from `ci.android.com` | Distribution terms must be confirmed per artifact | Build our own images from AOSP source and publish what we built. `[UNVERIFIED — AOSP-IMAGE-REDIST]` |

---

## 5. Entitlements

| Entitlement | Who carries it | Why | Cost |
| --- | --- | --- | --- |
| `com.apple.security.hypervisor` | **QEMU helper only** | `-accel hvf` calls Hypervisor.framework | Free; part of a normal Developer ID profile |
| `com.apple.security.virtualization` | VZ prototype helper only | `VZVirtualMachine` refuses to start without it | Free |
| `com.apple.vm.networking` | Nobody, for now | Required for bridged networking | **Managed entitlement — must be requested from Apple.** Avoided by defaulting to user-mode networking |
| `com.apple.security.cs.disable-library-validation` | **Nobody** | Would be needed only if we loaded third-party dylibs into our own process | Avoided by design: the helper-process topology means we never do |

The application itself carries the *minimum*: no hypervisor entitlement, no
virtualization entitlement. It cannot start a VM, and that is the point.

Sandboxing: the shipping app is **not** App Sandboxed initially. The DMG target
does not require it, and virtual-device storage plus helper spawning make it a
significant piece of work. Revisit only if a Mac App Store build is ever
considered — which the QEMU dependency would independently block.

---

## 6. Multiemu's own originality obligations

- All branding, icons, graphics, layout, visual styling, sounds and source are
  original to Multiemu.
- Other desktop Android emulators may be studied as *functional* UX references.
  No proprietary source, binaries, assets, icons, trademarks or copyrighted
  graphics are copied, and no undocumented third-party behaviour is depended on.
- Product naming must not imply affiliation with Google, Android, Apple or any
  other emulator vendor. "Android" is a trademark of Google LLC; use in
  descriptive text must follow Google's brand guidelines.

---

## 7. Secrets

Never in source control: Developer ID certificates and `.p12` files, App Store
Connect API keys, notarization credentials, app-specific passwords, provisioning
profiles, machine-specific keychain references. `.gitignore` blocks the usual
filenames; signing scripts read them from the keychain or from environment
variables supplied by the release machine.
