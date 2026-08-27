# Compatibility matrix

**Generated — do not edit.** Every row below is the result of running the
evidence named in `Sources/MultiemuCompatibility/ClaimRegistry.swift`.
Regenerate with:

```bash
scripts/compatibility.sh
```

| | |
| --- | --- |
| Generated | 2026-08-27T17:13:51Z |
| Host | Apple M5 · Apple Silicon (arm64) · macOS 26.5.2 · 16.00 GiB |
| Duration | 15 s |
| Test suites reported | 67 |
| Spikes run | none |

## What the words mean

| Status | Meaning |
| --- | --- |
| **PASS** | The named evidence ran, in this run, and passed. |
| inherited | The logic does not vary by architecture, so the Apple Silicon result stands. **Not** a claim that anything ran on Intel. |
| **FAIL** | The named evidence ran and failed — or does not exist, which is drift. |
| NOT TESTED | Nothing ran. Not a claim of working. |
| BLOCKED | Waiting on another milestone, with the reason given. |
| UNAVAILABLE | Cannot be checked in this environment, with the reason given. |

"Host-independent" means the logic does not vary by architecture, so the
Apple Silicon result carries over. It does **not** mean it was run on Intel.

## Summary

| Result | Claims |
| --- | --- |
| PASS | 25 |
| NOT TESTED | 12 |
| BLOCKED | 3 |
| UNAVAILABLE | 6 |
| **Total** | **46** |

No claim that could be checked failed.

## Host and guest architecture

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| A backend is selected from real host capabilities | **PASS** | inherited | M1 | suite "Backend selection matrix" |
| Host capabilities are probed rather than assumed | **PASS** | UNAVAILABLE | M1 | suite "HostCapabilityProbe" |
| A device is refused when the host cannot honour it | **PASS** | inherited | M1 | suite "Resource preflight" |

- *A backend is selected from real host capabilities* — The selection logic is host-independent; which backend it picks on an Intel Mac is untested.

## Android versions

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| A modern Android release boots and runs (17 verified) | UNAVAILABLE | UNAVAILABLE | M4 | Android 17 (SDK 37) boots to sys.boot_completed in 3.46 s median, launcher resumed — verified by hand and recorded in VERIFY.md -> CUTTLEFISH-WITHOUT-CVD. Not run by this harness: it needs a locally installed image, which is not in the repository. |
| Android 9 (API 28) boots and runs | UNAVAILABLE | UNAVAILABLE | M4 | no Android 9 image has been obtained; the image in use is Android 17 |

- *A modern Android release boots and runs (17 verified)* — The development target: best virtio support, so it is validated first.
- *Android 9 (API 28) boots and runs* — The product floor, and expected to be the hardest target: it predates much of the virtio and generic-kernel work. Validated last.

## Boot and lifecycle

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| A Linux guest boots to userspace under hardware virtualization | NOT TESTED | UNAVAILABLE | M2 | multiemu-multi-instance-spike was not run |
| An Android guest boots | UNAVAILABLE | UNAVAILABLE | M4 | Android 17 (SDK 37) boots to sys.boot_completed in 3.46 s median, launcher resumed — verified by hand and recorded in VERIFY.md -> CUTTLEFISH-WITHOUT-CVD. Not run by this harness: it needs a locally installed image, which is not in the repository. |
| The lifecycle state machine survives its backend dying | **PASS** | inherited | M3 | suite "Emulator session" |
| The QMP control channel drives a live guest | **PASS** | UNAVAILABLE | M3 | suite "QMP client" |

## Graphics and display

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| Guest frames arrive over D-Bus and decode | **PASS** | UNAVAILABLE | M5 | suite "D-Bus framebuffer decoding" |
| Frames are presented through Metal at guest resolution | **PASS** | UNAVAILABLE | M5 | suite "Metal presentation" |
| Scaling modes preserve the guest's aspect ratio | **PASS** | inherited | M5 | suite "Display scaling geometry" |
| The host frame path fits inside a 60 fps budget | **PASS** | UNAVAILABLE | M5 | suite "Presentation performance" |
| Every display preset applies to a running guest | NOT TESTED | UNAVAILABLE | M12 | multiemu-display-control-spike was not run |
| The guest display rotates at runtime | NOT TESTED | UNAVAILABLE | M12 | multiemu-display-control-spike was not run |
| The guest display records to a playable file in real time | NOT TESTED | UNAVAILABLE | M13 | multiemu-recording-spike was not run |
| Recording does not slow the interactive frame path | **PASS** | inherited | M13 | suite "Recording performance" |

## Input

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| Host keys map to Linux evdev codes the guest accepts | **PASS** | inherited | M6 | suite "Keyboard mapping" |
| Pointer coordinates map into guest space | **PASS** | inherited | M6 | suite "Pointer coordinate mapping" |
| Keys and gamepad controls map to screen positions | NOT TESTED | inherited (NOT TESTED) | M16 | multiemu-input-mapping-spike was not run |
| Input profiles persist per device and older files still open | **PASS** | inherited | M16 | suite "Input profile persistence" |
| A physical game controller drives a guest | UNAVAILABLE | UNAVAILABLE | M16 | no controller is available, and GCVirtualController does not exist on macOS |
| A guest reads the touch coordinates that were sent | BLOCKED | BLOCKED | M16 | blocked by M16: the Linux fixture exports no evdev interface; an Android guest now boots, but guest-side touch delivery has not been checked in it |

## Storage and snapshots

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| Virtual disks are created sparsely through qemu-img | **PASS** | UNAVAILABLE | M9 | suite "Virtual disks" |
| Device profiles persist and reload faithfully | **PASS** | inherited | M9 | suite "Virtual device store" |
| Guest data survives a full restart | NOT TESTED | UNAVAILABLE | M9 | multiemu-persistence-spike was not run |
| Snapshots capture and restore RAM as well as disk | NOT TESTED | UNAVAILABLE | M15 | multiemu-snapshot-spike was not run |
| Android images are verified before boot and their headers parsed | **PASS** | inherited | M4 | suite "Android boot image" |
| A GPT composite disk is built as Android expects | **PASS** | inherited | M4 | suite "GPT composite disk" |

## Networking

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| Guest networking is configured, and forwards validated | **PASS** | inherited | M7 | suite "Guest networking configuration" |
| Traffic flows both ways, and forwards bind loopback only | NOT TESTED | UNAVAILABLE | M7 | multiemu-network-spike was not run |
| Host ports are allocated without collision | **PASS** | inherited | M7 | suite "Host port allocation" |
| A device appears in `adb devices` and a shell works | UNAVAILABLE | UNAVAILABLE | M8 | ADB connects and `shell:` works over the loopback forward once the guest is routed (ip route add 10.0.2.0/24 dev buried_eth0 table local_network — Android never consults the main table) and adbd is switched to TCP; see scripts/enable-guest-adb.sh. Not run by this harness: it needs a booted guest and a locally installed image |

## File exchange and clipboard

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| Guest-supplied paths stay confined to the shared folder | NOT TESTED | inherited (NOT TESTED) | M14 | multiemu-sharing-spike was not run |
| A shared folder is exported read-only, with its path escaped | **PASS** | inherited | M14 | suite "Shared folder arguments" |
| A shared directory is readable inside the guest | BLOCKED | BLOCKED | M14 | blocked by M14: no transport in common: the host offers only virtio-9p and the Android guest supports only virtiofs (no 9p in /proc/filesystems, no 9p module). QEMU on macOS exposes no virtio-fs device and there is no virtiofsd |
| Clipboard text crosses in both directions | BLOCKED | BLOCKED | M14 | blocked by M14: QEMU mediates clipboard to a guest agent, which no stock Android image runs; the ADB route Google uses needs M8, blocked by the same image lacking virtio_net |

## Multiple devices

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| Several devices run at once with separate helper processes | NOT TESTED | UNAVAILABLE | M18 | multiemu-multi-instance-spike was not run |
| Admission accounts for devices already running | NOT TESTED | inherited (NOT TESTED) | M18 | multiemu-multi-instance-spike was not run |

## Application and packaging

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| The application finds its helper binaries, and says which it used | **PASS** | inherited | M17 | suite "Helper location" |
| The QEMU command line is built as intended | **PASS** | inherited | M2 | suite "QEMU command line" |
| A signed, notarized DMG installs on a clean Mac | UNAVAILABLE | UNAVAILABLE | M21 | not signed by choice: this project ships an unsigned, MIT-licensed build (`release.sh --unsigned`). The signed pipeline exists and rehearses end to end for anyone who wants one |
| A disk image builds, mounts, and carries an app that still verifies | NOT TESTED | inherited (NOT TESTED) | M21 | scripts/make-dmg.sh was not run |

- *A disk image builds, mounts, and carries an app that still verifies* — Checked by scripts/make-dmg.sh, which mounts the image it just built and verifies the bundle inside it.

## Failure and edge cases

| Capability | Apple Silicon | Intel | Milestone | Evidence |
| --- | --- | --- | --- | --- |
| A backend killed from outside is detected and recovered from | **PASS** | UNAVAILABLE | M3 | suite "Emulator session" |
| A corrupt or missing guest image fails as itself, not as a timeout | **PASS** | inherited | M4 | suite "Image store" |
| An unavailable backend is reported with a remedy | **PASS** | inherited | M2 | suite "Backend availability" |

## What this run could not cover

| Capability | Why |
| --- | --- |
| A modern Android release boots and runs (17 verified) | Android 17 (SDK 37) boots to sys.boot_completed in 3.46 s median, launcher resumed — verified by hand and recorded in VERIFY.md -> CUTTLEFISH-WITHOUT-CVD. Not run by this harness: it needs a locally installed image, which is not in the repository. |
| Android 9 (API 28) boots and runs | no Android 9 image has been obtained; the image in use is Android 17 |
| A Linux guest boots to userspace under hardware virtualization | multiemu-multi-instance-spike was not run |
| An Android guest boots | Android 17 (SDK 37) boots to sys.boot_completed in 3.46 s median, launcher resumed — verified by hand and recorded in VERIFY.md -> CUTTLEFISH-WITHOUT-CVD. Not run by this harness: it needs a locally installed image, which is not in the repository. |
| Every display preset applies to a running guest | multiemu-display-control-spike was not run |
| The guest display rotates at runtime | multiemu-display-control-spike was not run |
| The guest display records to a playable file in real time | multiemu-recording-spike was not run |
| Keys and gamepad controls map to screen positions | multiemu-input-mapping-spike was not run |
| A physical game controller drives a guest | no controller is available, and GCVirtualController does not exist on macOS |
| A guest reads the touch coordinates that were sent | blocked by M16: the Linux fixture exports no evdev interface; an Android guest now boots, but guest-side touch delivery has not been checked in it |
| Guest data survives a full restart | multiemu-persistence-spike was not run |
| Snapshots capture and restore RAM as well as disk | multiemu-snapshot-spike was not run |
| Traffic flows both ways, and forwards bind loopback only | multiemu-network-spike was not run |
| A device appears in `adb devices` and a shell works | ADB connects and `shell:` works over the loopback forward once the guest is routed (ip route add 10.0.2.0/24 dev buried_eth0 table local_network — Android never consults the main table) and adbd is switched to TCP; see scripts/enable-guest-adb.sh. Not run by this harness: it needs a booted guest and a locally installed image |
| Guest-supplied paths stay confined to the shared folder | multiemu-sharing-spike was not run |
| A shared directory is readable inside the guest | blocked by M14: no transport in common: the host offers only virtio-9p and the Android guest supports only virtiofs (no 9p in /proc/filesystems, no 9p module). QEMU on macOS exposes no virtio-fs device and there is no virtiofsd |
| Clipboard text crosses in both directions | blocked by M14: QEMU mediates clipboard to a guest agent, which no stock Android image runs; the ADB route Google uses needs M8, blocked by the same image lacking virtio_net |
| Several devices run at once with separate helper processes | multiemu-multi-instance-spike was not run |
| Admission accounts for devices already running | multiemu-multi-instance-spike was not run |
| A signed, notarized DMG installs on a clean Mac | not signed by choice: this project ships an unsigned, MIT-licensed build (`release.sh --unsigned`). The signed pipeline exists and rehearses end to end for anyone who wants one |
| A disk image builds, mounts, and carries an app that still verifies | scripts/make-dmg.sh was not run |

Intel results are absent throughout: no Intel Mac is available to this
project, so no row claims one.

## What this project has to test with

A matrix is only as honest as its coverage, so the gaps are listed rather
than left to be inferred from missing rows.

| Resource | Available | Consequence |
| --- | --- | --- |
| Apple M5 · Apple Silicon (arm64) · macOS 26.5.2 · 16.00 GiB | **yes** — the development machine | Every Apple Silicon result above is a real measurement |
| An Intel Mac | no | No Intel row claims a result. Host-independent logic is marked as such and inherits the Apple Silicon verdict; nothing else does. |
| An Android system image | no — `ci.android.com` is unreachable from this environment | Every Android claim is blocked. The boot, input, audio and file-sharing paths are verified against a Linux fixture instead, which carries no evdev, no sound and no 9p driver. |
| A physical game controller | no — and `GCVirtualController` does not exist on macOS, so one cannot be synthesised | Gamepad translation is unit-tested; no claim is made about real hardware. |
| A Developer ID identity | no | Notarization and the shipped DMG remain unverified. |

These gaps are project risk, recorded here rather than papered over.
