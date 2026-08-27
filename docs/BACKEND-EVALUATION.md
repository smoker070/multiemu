# Backend evaluation

Decision record for Multiemu's virtualization/emulation core.
Written before backend implementation begins (Milestone 1), to be revised with
measurements from Milestone 2.

Status of every claim below: statements about **licensing**, **published API
surface** and **architecture** are stated as fact. Statements about **runtime
behaviour on macOS** that this project has not yet executed are marked
`[UNVERIFIED]` and carry an entry in `VERIFY.md`.

---

## 1. The question

An Android guest needs four things a plain Linux VM does not:

1. **A GPU the guest can actually use.** SurfaceFlinger composites every frame,
   and Android applications render through OpenGL ES / Vulkan. A 2D-only
   framebuffer forces software rasterisation (SwiftShader) for the entire UI.
2. **A device model we control.** Sensors, battery, GPS, camera, telephony and
   the clipboard have no standard virtio device. Every Android emulator solves
   this with either custom devices (goldfish) or a guest-side agent over a
   transport (vsock / virtio-console).
3. **Frames delivered to *us*, not to a window the engine owns.** The product
   requires screenshots, screen recording, scaling independent of the guest's
   logical resolution, and eventually multiple simultaneous instances.
4. **Crash isolation.** Android guests wedge. The macOS application's control
   state must survive the engine dying.

The candidates are evaluated against those four needs, plus the published
performance targets.

---

## 2. Candidate: Apple Virtualization.framework

`VZVirtualMachine`, macOS 11+. On Apple Silicon it runs arm64 Linux guests; on
Intel it runs x86_64 Linux guests. Requires the `com.apple.security.virtualization`
entitlement.

**What it gives us, for free and with Apple maintaining it**

- A well-optimised VMM built on Hypervisor.framework.
- Direct kernel boot (`VZLinuxBootLoader`) — an Android `boot.img` unpacks to
  exactly the kernel + ramdisk this expects — and EFI boot (`VZEFIBootLoader`,
  macOS 13+).
- virtio block, network (NAT and bridged), console/serial, entropy, balloon,
  file system (virtio-fs), sound, socket (vsock), USB keyboard and pointing
  devices, NVMe (macOS 14+), XHCI (macOS 15+).
- Clipboard via a SPICE agent port (macOS 13+).
- Save/restore of VM state (macOS 14+), gated by
  `VZVirtualMachineConfiguration.validateSaveRestoreSupport()`. `[UNVERIFIED]`
- Zero redistribution obligations. No GPL anywhere.

**Why it is not the primary Android backend**

| Requirement | Virtualization.framework |
| --- | --- |
| 3D-capable GPU for the guest | `VZVirtioGraphicsDeviceConfiguration` is a virtio-gpu **2D** device. There is no API to attach virglrenderer, Venus, or gfxstream as the renderer. `[UNVERIFIED — VZ-VIRTIO-GPU-3D]` |
| Controllable device model | Fixed. No custom PCI/MMIO device can be injected, so goldfish-style sensor/battery/GPS/camera devices are impossible. They would have to be tunnelled over vsock with guest-side HALs written by us. |
| Frames delivered to us | Display is surfaced only through `VZVirtualMachineView` (an `NSView`). There is no documented API returning raw scanout buffers, so screenshots and recording must go through view capture, and headless/multi-instance rendering is awkward. |
| Crash isolation | The VM runs **inside the calling process**. A wedged VM is a wedged application unless we run VZ in our own helper process anyway — which removes VZ's simplicity advantage. |
| CPU configuration | Core count only. No CPU model or feature selection. |

The GPU limitation alone is decisive. Android without GPU acceleration will not
sustain the 30 FPS minimum at 1920×1080, let alone reach 60 FPS.

**Verdict: comparison prototype, not the product backend.** Milestone 2 still
builds a small VZ path, for two reasons: it is the fastest possible way to prove
"a Linux kernel boots under hardware virtualization on this Mac", and it gives us
an Apple-maintained performance baseline to measure QEMU against.

### 2a. Why Rosetta is not an x86 Android strategy

`VZLinuxRosettaDirectoryShare` (macOS 13+) lets an **arm64 Linux** guest execute
**x86_64 Linux** userspace binaries via `binfmt_misc`. It is not a path to
running x86 Android on Apple Silicon:

- Android userspace is bionic + ART on a Linux kernel, not a glibc Linux
  distribution. An x86_64 Android system image is a whole OS image, not a set of
  ELF binaries dropped into an arm64 rootfs.
- Android dispatches application code through the Android runtime and its own
  ABI-specific native libraries, not through `binfmt_misc`.
- The share translates userspace only. An x86_64 Android **kernel** still needs
  x86_64 CPU virtualization, which Apple Silicon does not have.

Multiemu's host probe reports Rosetta availability for host-inventory
completeness and for nothing else.

---

## 3. Candidate: our own VMM on Hypervisor.framework

`hv_vm_create`, `hv_vcpu_create`, `hv_vcpu_run`, `hv_vm_map`, plus the
`com.apple.security.hypervisor` entitlement. This is what both
Virtualization.framework and QEMU's `hvf` accelerator are built on.

Hypervisor.framework gives us guest execution and stage-2 memory mapping. It
gives us **no** firmware, **no** interrupt controller wiring beyond what recent
macOS releases expose, **no** timers, **no** device tree, and **no** devices.

To reach an Android UI we would have to write, at minimum:

- PSCI implementation and CPU bring-up (arm64) / SMP boot path (x86_64)
- ~~Interrupt controller~~ — **revised in Milestone 2.** macOS 15 ships a
  complete in-kernel GICv3 API: `hv_gic_create`, distributor/redistributor base
  configuration, MSI region configuration, ICC/ICH/ICV register access, and GIC
  **state** access for save/restore, all annotated `API_AVAILABLE(macos(15.0))`.
  The largest single component is provided by the OS.
  (`VERIFY.md` → `HV-GIC-API`)
- ARM generic timer / HPET+TSC handling
- Device tree (arm64) or ACPI tables (x86_64) generation
- A virtio transport (virtio-mmio or virtio-pci) and the full virtqueue machinery
- virtio-blk, virtio-net, virtio-console, virtio-input, virtio-snd, virtio-gpu
- A 3D renderer behind virtio-gpu

Milestone 2 also proved the *execution* half is genuinely available to us:
`multiemu-hvprobe` created a VM, mapped guest memory, created a vCPU and ran
guest instructions, reading back the expected register value in 9 µs.

So the honest revised position is: the remaining work is the **device model**,
not the CPU or the interrupt controller. That is still months of specialist
effort that must complete *before* Android boots even once, so it remains the
wrong **first** backend — but it is a materially cheaper future option than
stated in Milestone 1, and the one that removes the GPL obligation entirely.

**Verdict: not scheduled.** The value of naming it is that the backend
abstraction must not assume a subprocess. `BackendKind.nativeHypervisor` exists
in the catalogue so this option stays architecturally open — and so the eventual
removal of the GPL obligation stays a strategy rather than a rewrite.

---

## 4. Candidate: QEMU

Upstream `qemu-system-aarch64` / `qemu-system-x86_64`, run as a **separate
process**, accelerated with `-accel hvf`, controlled over a QMP socket.

**What it gives us**

| Requirement | QEMU |
| --- | --- |
| 3D-capable GPU | `virtio-gpu` with an external renderer. virglrenderer (MIT) and gfxstream (Apache-2.0) both exist; gfxstream is the renderer Google's own Android Emulator uses and it builds for macOS hosts. |
| Controllable device model | Complete. Any device QEMU has, plus `vhost-user` devices implemented by our own processes. |
| Frames delivered to us | Via `vhost-user-gpu`: QEMU hands virtio-gpu command processing to an external renderer process that *we* own, so the composited output lands in our Metal texture instead of a QEMU window. `[UNVERIFIED — QEMU-VHOST-USER-GPU-MACOS]` |
| Crash isolation | Inherent. QEMU is a separate process; it can die without touching the application. |
| Snapshots | qcow2 internal snapshots plus `savevm`/`loadvm`, drivable over QMP. |
| Control plane | QMP: a line-delimited JSON protocol over a UNIX socket. Exactly the IPC an emulator lifecycle coordinator wants. |
| Both host architectures | `hvf` accelerates arm64 guests on Apple Silicon and x86_64 guests on Intel from one code base. |
| Cross-architecture | TCG. Works; one to two orders of magnitude slower. Offered, never defaulted. |

**Costs and open risks**

1. **License.** QEMU's system emulator is **GPL-2.0-only**. It must ship as a
   separate executable, never linked into Multiemu, and we must publish the
   corresponding source of the exact binary we ship. See
   `DEPENDENCIES-AND-LICENSING.md`. This is the single largest ongoing
   obligation the decision creates.
2. **Packaging.** Notarization requires every Mach-O in the bundle to be signed
   with Developer ID and the hardened runtime. A Homebrew QEMU drags in dozens
   of dylibs. We must build QEMU ourselves with a controlled, minimal dependency
   set and re-sign everything. Non-trivial; scheduled for M21 but prototyped
   early because it can invalidate the whole approach if it fails.
3. **`vhost-user-gpu` on macOS.** vhost-user depends on shared memory and file
   descriptor passing over UNIX sockets. This project has not verified that
   QEMU's vhost-user support works on macOS. `[UNVERIFIED — QEMU-VHOST-USER-GPU-MACOS]`
   Fallback if it does not: patch QEMU with a Metal display backend (and publish
   that patch as source), or start 2D-only from a shared-memory scanout.
4. **vsock.** QEMU's `vhost-vsock-pci` requires `/dev/vhost-vsock`, which is a
   Linux host feature. macOS has no `vhost`. `[UNVERIFIED — QEMU-VSOCK-MACOS]`
   **Design consequence, taken now:** the guest control channel must not depend
   on vsock. Multiemu uses `virtio-console` for the guest agent and TCP for ADB.
5. **Networking privileges.** `-netdev user` (libslirp) is unprivileged and is
   the default. QEMU's `vmnet-*` backends need elevated privileges on macOS, so
   bridged networking is a later feature behind a privileged helper — a security
   surface we do not open in early milestones.

**Verdict: primary backend.**

---

## 5. Candidate: reusing the Android Emulator

Google's `emulator` binary from the Android SDK already runs Android well on both
Mac architectures. It is not a product option: it ships under the Android SDK
License Agreement and **may not be redistributed** inside Multiemu's DMG.
Forking `platform/external/qemu` (GPLv2, heavily diverged from upstream, with a
build system of its own) trades the redistribution problem for an unbounded
maintenance problem.

It has one legitimate role: **a development-time reference oracle.** Installed
separately by a developer, it tells us what a known-good Android guest boot looks
like on this hardware and gives us a performance baseline to measure against.
It is never invoked by the shipping application and never bundled.

---

## 6. Decision

**One backend interface. QEMU + HVF as the only shipping implementation.
Virtualization.framework as a comparison prototype. Native VMM left open.**

Rationale:

- One backend *does* cover both host architectures, because `hvf` accelerates
  the matching guest architecture on each. The split that matters is not
  Apple Silicon vs Intel — it is **guest architecture matches host** vs
  **does not**.
- Therefore the architecture-specific interface is not "AppleSiliconBackend"
  and "IntelBackend". It is one backend that takes a `GuestArchitecture` and
  reports the resulting `AccelerationMode` and `SupportLevel`. That policy is
  already implemented in `BackendSelector` and is covered by the test suite.
- Everything the UI needs to know is expressed as capabilities
  (`BackendCapability`), not as host checks. The snapshot button is shown when
  the active backend reports `.snapshots`, not when the host is Apple Silicon.

### Process topology

```
Multiemu.app  (SwiftUI/AppKit, no virtualization code, no GPL code)
      |  XPC
      v
MultiemuVMHost.xpc  (lifecycle coordinator; owns the child processes)
      |  spawn + QMP over UNIX socket        |  spawn + vhost-user socket
      v                                      v
qemu-system-*  (GPL-2.0, unmodified,         MultiemuRenderer  (Metal; receives
signed with com.apple.security.hypervisor)   virtio-gpu commands, produces frames)
```

Consequences of this topology, all of them requirements the product already sets:

- The unstable engine is never in the UI process.
- The GPL binary is never linked into our code — it is spawned, and it talks
  over a socket.
- The entitlement that grants hypervisor access sits on the QEMU helper alone,
  not on the application. Least privilege falls out of the design.
- Backend death is an event on a socket, not a crash. Recovery is a supported
  state transition.

### Fallback paths

| Risk | Outcome |
| --- | --- |
| `vhost-user-gpu` does not work on macOS | **THIS HAPPENED.** `vhost-user-gpu-pci` is not a valid device model on macOS; there are no vhost-user devices at all. The M1 graphics plan is dead. |
| `-accel hvf` proves unreliable for arm64 guests | **Did not happen.** Five consecutive clean boots of Linux 6.12.1, 0.305 s to userspace, no variance. |
| QEMU cannot be built and notarized acceptably | Still open. Requires a build from pinned source and a Developer ID identity. |

### The graphics plan, revised again in Milestone 5 — now on measurements

`vhost-user-gpu` does not exist on macOS (M2). Milestone 5 tested the
alternatives rather than reasoning about them.

| Path | Status | Evidence |
| --- | --- | --- |
| **`-display dbus,p2p=on`** | **Chosen and working.** Frames received and decoded | 53 scanouts, first at 0.116 s, 1920×1080 `x8r8g8b8`, decode 0.21 ms/frame |
| VNC / RFB | Fallback for correctness work only | Real pixels captured, but **8.5 fps** median at 1080p, p95 934 ms; same client does 4910 MiB/s on plain loopback, so the server is the bottleneck |
| Patched QEMU with a native display backend | Held in reserve | Not needed unless D-Bus frame delivery fails |
| 3D via virgl | Blocked on our own build | Guest DRM reports `-virgl -resource_blob` |

The decision: **build the D-Bus display client.** It is the only path that keeps
QEMU unpatched, keeps the GPL boundary clean, and is not already disqualified on
throughput. VNC stays wired up as a diagnostic and as a way to make progress on
input, scaling and screenshots before the D-Bus client is finished — pixels on
screen at 8 fps beats no pixels while the real path is built.

Frame delivery is now proven: `org.qemu.Display1.Console.RegisterListener`
accepted, and QEMU calls `Scanout` on Multiemu with the framebuffer inline.
Decoding costs 0.21 ms for a 3.9 MiB frame against 117 ms for the same
framebuffer over VNC — a 550× difference that settles the choice on measurement
rather than preference. The patched-QEMU fallback is no longer needed.

What remains for the product is presentation rather than transport: Metal
rendering, HiDPI, scaling independent of the guest's logical resolution, and
sustained-rate measurement under a real workload rather than a static console.

This is what the Milestone 2 spike was for. Finding it now costs a redesign of
one milestone; finding it at Milestone 5 would have cost the schedule, and at
Milestone 21 the backend.


---

## 7. Milestone 2 evidence

Three of this document's load-bearing claims were assumptions when it was
written. They are now measured on Apple M5 / macOS 26.5.2. Full detail in
`VERIFY.md`.

| Claim | Status | Evidence |
| --- | --- | --- |
| Virtualization.framework's virtio-gpu is 2D with no attachable renderer | **CONFIRMED** | The complete public property surface is `scanouts` → `{widthInPixels, heightInPixels}`. Nothing matching `3d`/`accel`/`render`/`virgl`/`venus`/`gfxstream`/`opengl`/`metal`/`gpu` exists on any graphics configuration class. |
| A helper needs `com.apple.security.hypervisor` and nothing more | **CONFIRMED** | Same binary: `HV_DENIED` without it, `HV_SUCCESS` with it, on an ad-hoc signature. |
| Hardware virtualization is reachable from our own code | **CONFIRMED** | Guest code executed: ESR EC `0x16` (HVC64), guest `x0 == 42`, 9 µs. |
| VZ can save and restore Linux VM state | **CONFIRMED (positive)** | `validateSaveRestoreSupport()` returns supported for a Linux device set; both selectors exist. |
| macOS 15 exposes in-kernel GIC APIs | **CONFIRMED** | Full `hv_gic_*` surface in the SDK at `macos(15.0)`, including GIC state save/restore. |

The graphics finding is the one that matters most: it is the single argument
that decided the backend, and it is now evidence rather than recollection.

**What is still assumed.** Every claim about QEMU's *runtime* behaviour on macOS
— HVF maturity for aarch64 guests, `vhost-user-gpu`, vsock, `vmnet` privileges,
and notarization of a bundled build — remains open, because QEMU could not be
downloaded during this milestone. The design is unchanged, but it rests on
those five open items, and `QEMU-VHOST-USER-GPU-MACOS` is still the highest-risk
unknown in the project.
