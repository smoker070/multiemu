# Multiemu

An Android emulator for macOS (Apple Silicon and Intel), built as a native
Swift/SwiftUI/AppKit application on top of an isolated, replaceable
virtualization backend.

**Status: Milestones 1–10, 12, 13 and 15–20 complete. Milestones 11 (audio) and
14 (clipboard) are partial with the reasons recorded. Milestone 21 ships as an
open-source, unsigned build by choice.**

Android 17 boots to the launcher in about **3.7 seconds** under QEMU with
Hypervisor.framework, runs at **37–39 FPS** under a scripted workload, and is
driven over a first-party ADB client — the wire protocol is implemented here
rather than shipping Google's binary, which is not redistributable. APKs
install and launch. Files move both ways. `docs/ROADMAP.md` records what each
milestone achieved and, where something is partial, exactly what blocks it.

Two limits worth knowing before you start: **app audio does not reach the host**
(the AOSP images available today route it to a stub driver — output is proven
to work at the ALSA layer, so this lands when an image with a real audio HAL
does), and **the clipboard does not work** (Android refuses clipboard access to
anything that is not the foreground app).

## Licence

MIT — see [LICENSE](LICENSE). Fork it, ship it, sell it.

That covers Multiemu's own code. QEMU is run as a **separate child process and
never linked**, so its GPL-2.0 does not reach this code; but a build that
*bundles* QEMU binaries must carry QEMU's `COPYING` and the corresponding
source, and `scripts/collect-licenses.sh` refuses to assemble one that does not.
Android system images are not in this repository and carry their own terms.
`docs/DEPENDENCIES-AND-LICENSING.md` is the full map.

## Requirements

| Item | Requirement |
| --- | --- |
| Host OS | macOS 14.0 or later |
| Host CPU | Apple Silicon (arm64) or Intel (x86_64) |
| Toolchain | Xcode 15.3+ / Swift 5.10+ (developed against Xcode 26.6 / Swift 6.3) |
| Guest OS | Android 9 (API 28) or later |

## Quick start

```bash
swift build && swift test
swift run multiemu-probe --format text
```

| Tool | What it does |
| --- | --- |
| `multiemu-probe` | Host capability report: CPU, memory, storage, Metal, virtualization, entitlements, missing prerequisites, and which backend would be selected per guest architecture. |
| `multiemu-hvprobe` | Creates a VM, maps guest memory, creates a vCPU and **executes guest code** under Hypervisor.framework. Must be signed first (see below). |
| `multiemu-vzprobe` | Reads Virtualization.framework's actual API surface off the running system. |
| `multiemu-boot` | Boots a Linux kernel under QEMU and reports a timed boot timeline. Needs QEMU and a kernel. |
| `multiemu-session` | Drives a full guest lifecycle through the coordinator. `--mode crash` kills the backend from outside and verifies recovery. |
| `multiemu-display-window` | Boots a guest, presents it in a real macOS window through Metal, accepts keyboard/mouse input, and captures a screenshot at guest resolution. |
| `multiemu-snapshot-spike` | Proves snapshots capture and restore RAM as well as disk, and times both. |
| `multiemu-persistence-spike` | Proves guest data survives a full restart, the disk stays sparse, and factory reset clears it. |
| `multiemu-network-spike` | Verifies guest networking in both directions on loopback, and that forwards bind only `127.0.0.1`. |
| `multiemu-input-spike` | Proves input reaches the guest by typing a shell command and reading the result back over serial. |
| `multiemu-display-spike` | Boots a guest, attaches QEMU's D-Bus display channel, registers a listener and writes a received frame to PNG. |
| `multiemu-image` | `plan` / `install` / `verify` / `unpack` / `inspect` / `composite` / `traits` for Android image sets. `install` reads the image for the kernel arguments it needs; `traits` shows what it detected and why. `inspect` reads any `boot.img` or `vendor_boot.img` header; `composite` builds the GPT disk Android expects. |
| `multiemu-device` | `create` / `list` / `reset` / `delete` virtual devices from a terminal, through the same store the application uses. |
| `multiemu-compat` | Runs every claim the compatibility matrix makes and regenerates the matrix from the results. `--list` shows what backs each claim. |
| `multiemu-sharing-spike` | Checks that a shared folder reaches the guest as a device, that the clipboard channel answers, and that guest-supplied paths stay confined. |
| `multiemu-recording-spike` | Records a live guest, rotates it mid-recording, then reads the file back with AVFoundation to check it plays in real time at the stated size and rate. |
| `multiemu-display-control-spike` | Applies every display preset and a rotation to a running guest and reports what the guest actually did. `--start WxH` demonstrates the boot-allocation rule by breaking it. |
| `multiemu-input-mapping-spike` | Checks that a mapped key produces the right touch, that the guest enumerates a multitouch device only when configured, and reports honestly what it cannot prove. |
| `multiemu-multi-instance-spike` | Runs several devices at once and checks separate helpers, a shared read-only image, distinct loopback ports, and that admission accounts for what is already running. `--concurrent` starts them all in the same instant. |

`multiemu-hvprobe` and `multiemu-vzprobe` need entitlements, so sign them after
building:

```bash
swift build
scripts/sign-helper.sh .build/debug/multiemu-hvprobe Resources/entitlements/MultiemuQEMUHelper.entitlements
scripts/sign-helper.sh .build/debug/multiemu-vzprobe Resources/entitlements/MultiemuVZHelper.entitlements
```

Without the entitlement `multiemu-hvprobe` exits with `HV_DENIED` and says so —
that is the control result, not a bug.

## Installing a build

Multiemu ships **unsigned**, so macOS will refuse it on first launch. That is
expected, not a broken download — the project has no Apple Developer membership
and does not notarize.

After dragging the app out of the disk image, do one of:

```bash
xattr -d com.apple.quarantine /Applications/Multiemu.app
```

or right-click the app and choose **Open**, which offers the same override
through the interface.

If you would rather not do either, build it yourself — that path needs no
credentials and produces the same application:

```bash
git clone <this repository>
cd Multiemu
swift build && swift test
scripts/build-app.sh
open build/Multiemu.app
```

## The application

```bash
scripts/build-app.sh          # assembles and signs build/Multiemu.app
open build/Multiemu.app
```

The bundle is signed ad-hoc unless `CODESIGN_IDENTITY` names a real identity, in
which case the script also applies `--options runtime --timestamp`. It verifies
its own output with `codesign --verify --deep --strict` and `plutil -lint`.

Shipping builds carry their own QEMU in `Contents/Helpers/`, built from pinned
source by `scripts/build-qemu.sh` — the released app loads **no** libraries from
Homebrew and needs nothing installed. A development build falls back to a
Homebrew QEMU and says which it used; set `MULTIEMU_HELPER_DIR` to point at a
locally built one instead.

To produce a self-contained release:

```bash
scripts/build-qemu.sh fetch      # pinned tarball into vendor/
scripts/build-qemu.sh configure
scripts/build-qemu.sh build      # this one is a real compile; it uses every core
scripts/release.sh --unsigned --with-helpers --qemu-source /tmp/multiemu-qemu/qemu-11.1.0
```

The shell also takes flags used to verify it without a human at the keyboard:

| Flag | Effect |
| --- | --- |
| `--device-root <dir>` / `--image-root <dir>` | Use alternative stores, so test devices stay out of the real library. |
| `--appearance light\|dark` | Pin the interface to one appearance instead of following the system. |
| `--capture-window <file.png>` | Screenshot the window (or its sheet) and exit. |
| `--dump-accessibility <file.json>` | Write the view hierarchy and accessibility tree, then exit. |
| `--open-new-device` / `--open-settings` | Launch with that sheet already presented. |

Note both capture routes are partly blind, and neither is trusted alone:
screenshots do not composite the glass sidebar or the toolbar, and the view
hierarchy carries structure but no pixels. See `docs/VERIFY.md`.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Sources/MultiemuSupport` | Logging, signposts, error taxonomy. No policy. |
| `Sources/MultiemuHost` | Host capability detection (CPU, memory, storage, Metal, virtualization, code signing, external tools). |
| `Sources/MultiemuBackend` | Backend abstraction: descriptors, availability probes, selection policy, resource preflight, guest boot detection. |
| `Sources/MultiemuQEMU` | QEMU backend: configuration, command-line construction, process supervision, QMP message layer. |
| `Sources/MultiemuVZ` | Virtualization.framework comparison prototype and capability introspection. |
| `Sources/MultiemuLifecycle` | Emulator session: preflight, state, failure retention, restart. |
| `Sources/MultiemuImages` | Android image manifests, integrity verification, boot image parsing, guest plan. |
| `Sources/MultiemuDBus` | D-Bus wire protocol, SASL, peer-to-peer connections. |
| `Sources/MultiemuGraphics` | Guest frames, pixman formats, Metal renderer, scaling, PNG capture, QEMU display client. |
| `Sources/MultiemuDisks` | Virtual disk creation and sparse verification. |
| `Sources/MultiemuConfiguration` | Display profiles, device profiles, device store. |
| `Sources/MultiemuInput` | Key code maps, pointer coordinate mapping, QEMU D-Bus input client. |
| `Sources/MultiemuUI` | `GuestDisplayView`: Metal-backed, HiDPI, interactive. |
| `Sources/Multiemu*Probe`, `Sources/MultiemuBootCLI` | Command-line tools. |
| `Tests/Fixtures` | `fake-qemu.sh` — replays recorded guest consoles so the boot harness is testable without QEMU. |
| `docs/` | Architecture, backend evaluation, licensing map, guest image strategy, compatibility matrix, performance methodology, verification log. |
| `scripts/` | Toolchain checks and reproducible build/run helpers. |

## Releasing

```bash
scripts/release.sh --rehearsal     # everything that needs no credentials
scripts/release.sh                 # a real release; refuses without a Developer ID
```

The pipeline builds, collects licences, signs, notarizes, staples, packages a
disk image, mounts it to re-verify the app inside, and assesses both as
Gatekeeper would. Steps that cannot run are named in the summary rather than
skipped quietly. See [docs/RELEASE.md](docs/RELEASE.md), which also records the
GPL obligation that comes with shipping QEMU and the chosen update strategy.

## The compatibility matrix

```bash
scripts/compatibility.sh
```

`docs/COMPATIBILITY-MATRIX.md` is **generated**, not written. Every row is the
result of running the evidence named for it in
`Sources/MultiemuCompatibility/ClaimRegistry.swift`. A claim that names a test
suite which no longer exists is reported as a failure, so the matrix cannot
quietly outlive its tests. The script exits non-zero if any claim that could be
checked failed.

## Read these before writing code

1. `docs/BACKEND-EVALUATION.md` — why QEMU+HVF is the primary backend and what
   Virtualization.framework can and cannot do for an Android guest.
2. `docs/DEPENDENCIES-AND-LICENSING.md` — what may be redistributed inside a
   signed, notarized, closed-source DMG, and what may not.
3. `docs/GUEST-IMAGE-STRATEGY.md` — the Android 9+ guest image plan.
4. `docs/VERIFY.md` — every claim in this repository that is version-sensitive
   and has not yet been confirmed against primary documentation on this machine.

## Legal posture

Multiemu uses original branding, icons, graphics, layout and source code. Other
desktop Android emulators are referenced only as functional UX comparisons. No
proprietary third-party assets, binaries or source are used. Google Play
Services, Google Play Store, GMS and Google-distributed system images are **not**
bundled and are out of scope for redistribution.
