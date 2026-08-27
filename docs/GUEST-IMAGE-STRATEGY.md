# Android 9+ guest image strategy

The host work and the guest work are comparable in size. A macOS application
that can start a VM is worth nothing without an Android image that boots on the
device model that VM presents. This document defines that image.

---

## 1. Supported guest architectures

| Guest | Apple Silicon host | Intel host |
| --- | --- | --- |
| `arm64` (arm64-v8a) | **Primary.** Hardware virtualized. | Software translated — degraded. |
| `x86_64` | Software translated — degraded. | **Primary.** Hardware virtualized. |

The product-quality combination is always *guest architecture equals host
architecture*. Everything else is offered only behind an explicit advanced
option and labelled degraded. This rule is enforced in code by `BackendSelector`
and covered by `BackendSelectorTests`.

**Consequence for app compatibility:** an arm64 guest runs arm64 APKs. Android
applications shipping x86-only native libraries will not install there. Android's
own `arm64-v8a` requirement for Play-distributed apps makes this acceptable for
the common case, but it must be stated plainly in the product, not discovered by
users.

---

## 2. Boot method

**Direct kernel boot.** Not UEFI, not a bootloader.

An Android `boot.img` is a container holding a kernel and a ramdisk, and modern
Android additionally uses `vendor_boot.img` for vendor ramdisk fragments. Both
QEMU (`-kernel`/`-initrd`/`-append`) and Virtualization.framework
(`VZLinuxBootLoader`) take exactly those inputs.

Direct kernel boot is chosen because it:

- removes the bootloader from the boot-time budget, which matters against the
  45-second cold-boot target;
- makes the kernel command line a first-class, per-device configuration value
  (console, `androidboot.*` properties, display parameters);
- avoids emulating firmware we would otherwise have to ship and sign.

Image provisioning therefore includes an unpack step: `boot.img` and
`vendor_boot.img` are split into `kernel`, `ramdisk` and `vendor_ramdisk` at
install time, verified, and stored alongside the device.

---

## 3. Partition layout

| Partition | Backing | Persistence | Notes |
| --- | --- | --- | --- |
| `kernel` + `ramdisk` | Files on the host | Read-only | Extracted from `boot.img` |
| `vendor_ramdisk` | File on the host | Read-only | From `vendor_boot.img`, Android 11+ |
| `system` | virtio-blk, read-only | Shared between devices | Deduplicated across virtual devices that use the same image |
| `vendor` | virtio-blk, read-only | Shared | Contains the HALs that make the image VM-specific |
| `product`, `system_ext` | virtio-blk, read-only | Shared | Present on Android 10+ |
| `userdata` | qcow2, read-write, **sparse** | Per device | Default 32 GiB logical. Factory reset = delete and recreate. |
| `metadata` | qcow2, read-write | Per device | Required by Android 10+ |
| `cache` | qcow2, read-write | Per device | Android 9 only; later releases fold it into `userdata` |

Read-only partitions are opened `readonly=on` so several instances can share one
image file — a prerequisite for the multi-instance milestone, decided now
because retrofitting it later means rewriting the disk layer.

---

## 4. Which Android image

Three candidate sources, in the order they will be attempted:

### Option A — Cuttlefish guest artifacts (primary candidate)

AOSP's Cuttlefish targets (`aosp_cf_arm64_phone`, `aosp_cf_x86_64_phone`) are
built specifically to run as a **virtual machine on virtio devices**: virtio-blk,
virtio-net, virtio-console, virtio-gpu, virtio-input. That is precisely the
device model QEMU gives us, and it is the only mainstream AOSP configuration
where "Android on generic virtio hardware" is a supported, tested product rather
than a research project.

- **Licensing:** AOSP platform is Apache-2.0; the kernel is GPL-2.0. We build
  from source and publish the kernel tree. `[UNVERIFIED — AOSP-IMAGE-REDIST]`
- **Known risk:** Cuttlefish's normal launcher (`cvd`) is Linux-only and provides
  host-side services — including several over **vsock** — that we will not have.
  The guest must boot with those services absent, in a degraded but usable state.
  `[UNVERIFIED — CUTTLEFISH-WITHOUT-CVD]`
- **Design decision taken now:** Multiemu's guest control channel uses
  `virtio-console`, and ADB runs over TCP. Nothing in the critical path may
  depend on vsock, because QEMU's vsock support is a Linux-host feature.

### Option B — AOSP generic target plus a virtio kernel (fallback)

Build `aosp_arm64` (or a GSI) against an Android Common Kernel configured with
virtio-blk / net / console / input / gpu, and assemble a minimal vendor image:
`gralloc` on minigbm, `hwcomposer` on drm_hwcomposer, audio on virtio-snd,
sensors/battery/GPS as stubs behind our guest agent.

More work, more control, no dependence on Cuttlefish's assumptions.

### Option C — Android-x86 / BlissOS (Intel hosts only, evaluation)

Boots on generic x86 hardware via EFI. Useful as an early "does anything Android
appear on screen" datapoint on an Intel Mac. Not a product image: divergent from
AOSP, its own licensing review, and no arm64 equivalent.

### Android version coverage

- **Android 9 (API 28)** — the floor stated by the product. Predates several
  virtio-friendly changes and the `vendor_boot` split; expect it to be the
  *hardest*, not the easiest, target. It is validated last, not first.
- **A modern release (Android 14/15/16, selected during M4)** — the development
  target, because it has the best virtio and generic-kernel support.

Boot the modern release first. Treating Android 9 as "the simple one" because
it is older is the classic mistake here.

---

## 5. Image lifecycle

**Provisioning.** Images are never bundled in the DMG. They are downloaded from
a Multiemu-operated catalogue over HTTPS, verified by SHA-256 against a signed
manifest, and unpacked into the image store. Signature verification is
mandatory: an image is a kernel that runs with full guest privileges.

**Integrity.** Every partition file records a SHA-256 at install. The integrity
check runs on install, on demand from diagnostics, and after any crash-recovery
event. Read-only partitions must match; a mismatch is a hard failure, not a
warning.

**First boot vs cold boot.** First boot after device creation runs
`userdata` formatting, package optimisation (`dex2oat`) and initial property
generation. It is legitimately slow and is measured as its **own** metric — the
45-second cold-boot target explicitly does not apply to it.

**Persistence.** `userdata` and `metadata` are per-device qcow2 files that
survive restart, shutdown and application quit.

**Factory reset.** Delete and recreate `userdata` and `metadata`. Read-only
partitions are untouched. This is the recovery path when a guest becomes
unbootable.

**Android version upgrade.** Treated as a **new device**, not an in-place
upgrade. AOSP's OTA machinery assumes A/B partitions and update_engine; carrying
`userdata` across major releases without it risks unbootable devices. The UI
offers "create a new device from this image" and, if it is ever offered at all,
an explicit, clearly-risky data migration — never a silent upgrade.

---

## 6. Guest agent

A small Multiemu service inside the guest, over `virtio-console`, providing what
no standard virtio device does:

- clipboard exchange, both directions
- screen resolution / DPI / rotation changes applied at runtime
- battery, sensor, GPS and telephony simulation
- boot progress and health reporting, so the coordinator knows *why* a boot
  stalled rather than only that it timed out
- host/guest file exchange endpoints

Security boundary: the agent accepts only a fixed, versioned command set. It
never receives a host path or executes a host command, and the host never
executes anything the guest sends. Requests crossing this channel are validated
on the host side against a schema before any action is taken.

---

## 7. Open questions to resolve in Milestone 4

| ID | Question |
| --- | --- |
| `CUTTLEFISH-WITHOUT-CVD` | Does a Cuttlefish image boot to `sys.boot_completed=1` under plain QEMU without the `cvd` launcher and without vsock services? |
| `ANDROID9-VIRTIO` | Does an Android 9 image boot on a pure virtio device model, or does it need goldfish devices? |
| `KERNEL-CONFIG` | Which Android Common Kernel branch and config produces a kernel that boots under `-machine virt` with our device set? |
| `AOSP-IMAGE-REDIST` | Confirm the redistribution terms of every artifact we ship, per source. |
