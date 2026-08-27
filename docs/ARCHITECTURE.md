# Architecture

## Principles

1. **The UI never knows what a hypervisor is.** SwiftUI/AppKit code talks to the
   lifecycle coordinator and to view models. It has no `#if arch(...)`, no QEMU
   knowledge, no VZ imports. Swapping the backend must not touch a view.
2. **Architecture-dependent behaviour lives behind one interface.**
   `BackendSelector` is the only place that compares host and guest
   architectures. Everything else consumes its verdict.
3. **The engine is never in the UI process.** Crash-prone components run in
   helpers; the application survives their death by design.
4. **Capabilities, not host checks.** UI affordances are driven by
   `BackendCapability`, so a backend that lacks snapshots simply does not show
   the snapshot control.
5. **Nothing copyleft is linked.** The process split is a licensing requirement
   before it is anything else.

---

## Module map

Legend: **[M1]** exists now · **[Mn]** planned for that milestone.

### Process: `Multiemu.app`

| Module | Responsibility | Status |
| --- | --- | --- |
| `MultiemuApp` | macOS application shell: windows, toolbar, menus, settings | **M17** |
| `MultiemuUI` | Reusable views. `GuestDisplayView` (Metal-backed, HiDPI) delivered | **M5** |
| `MultiemuDeviceCLI` | `multiemu-device`: create, list, reset and delete devices from a terminal | **M17** |
| `MultiemuMultiInstanceSpike` | Verifies concurrent devices: separate helpers, shared read-only images, admission | **M18** |
| `MultiemuInputMappingSpike` | Verifies mapped input reaches QEMU and that the guest enumerates a multitouch device | **M16** |
| `MultiemuDisplayControlSpike` | Applies display profiles to a running guest and measures the scanouts it returns | **M12** |
| `MultiemuRecording` | `GuestRecorder` and `RecordingSession`: guest display to an H.264 file, off the frame path | **M13** |
| `MultiemuRecordingSpike` | Records a live guest and verifies the file with AVFoundation | **M13** |
| `MultiemuSharingSpike` | Verifies a shared folder reaches the guest, the clipboard channel, and path confinement | **M14** |
| `MultiemuCompatibility` | The claim registry, the runner that executes it, and the matrix generator | **M20** |
| `MultiemuCompatCLI` | `multiemu-compat`: runs the matrix and writes it | **M20** |
| `scripts/release.sh` | The release pipeline, with the credential boundary made explicit | **M21** |
| `scripts/collect-licenses.sh` | Licence materials, and the GPL source gate for shipping QEMU | **M21** |
| `scripts/make-dmg.sh` | Disk image; mounts what it built and re-verifies the bundle inside | **M21** |
| `MultiemuViewModels` | Observable state; the only layer views bind to. `AppModel`, `DeviceModel`, `HelperLocator` | **M17** |
| `MultiemuClient` | XPC client for the VM host service | M3 |
| `MultiemuConfiguration` | Display profiles and presets, virtual device profiles, device store, factory reset | **M9** |
| `MultiemuDiagnostics` | Diagnostics bundles, log export, crash reports | M15 |

### Process: `MultiemuVMHost.xpc`

| Module | Responsibility | Status |
| --- | --- | --- |
| `MultiemuLifecycle` | Emulator lifecycle coordinator: preflight, state mirroring, failure retention, restart | **M3** |
| `MultiemuBackend` | Backend abstraction: descriptors, availability, selection, resource preflight | **M1** |
| `MultiemuQEMU` | QEMU backend: process supervision, command-line construction, QMP client | **M3** |
| `MultiemuVZ` | Virtualization.framework capability introspection (comparison only) | **M2** |
| `MultiemuImages` | Android image manager: manifests, SHA-256 verification, boot/vendor_boot unpacking, guest plan | **M4** |
| `MultiemuDisks` | qcow2/raw creation via `qemu-img`, sparse verification | **M9** |
| `MultiemuNetwork` | Folded into `MultiemuBackend`: `GuestNetworkConfiguration`, `HostPortAllocator` | **M7** |
| `MultiemuADB` | ADB server supervision, device attachment, command execution | M8 |
| `MultiemuGuestAgent` | Host half of the guest agent protocol over virtio-console | M14 |

### Process: `MultiemuRenderer`

| Module | Responsibility | Status |
| --- | --- | --- |
| `MultiemuGraphics` | Guest frames, pixman formats, Metal renderer and scaling, PNG capture, QEMU D-Bus display client | **M5** |
| `MultiemuAudio` | CoreAudio output and microphone input bridging | M11 |

### Shared

| Module | Responsibility | Status |
| --- | --- | --- |
| `MultiemuSupport` | Logging, signposts, error taxonomy, byte formatting | **M1** |
| `MultiemuHost` | Host capability detection | **M1** |
| `MultiemuProtocol` | XPC and IPC message types shared across processes | M3 |
| `MultiemuDBus` | D-Bus wire protocol: marshalling, SASL (both roles), peer-to-peer connections, `SCM_RIGHTS` | **M5** |
| `MultiemuInput` | Key code maps, pointer coordinate mapping, QEMU D-Bus input client | **M6** |

---

## The backend interface

`MultiemuBackend` currently defines the **policy** half of the abstraction:

- `GuestArchitecture`, `BackendKind`, `AccelerationMode`, `SupportLevel`,
  `ImplementationStatus`, `BackendCapability`, `BackendDescriptor`
- `BackendSelector` — pure (host, guest) → backend decision
- `BackendAvailabilityProbing` — "can this backend start here right now"
- `ResourceValidator` — memory/storage/vCPU preflight

The **lifecycle** half was committed in Milestone 3, once QMP's real behaviour
was observable:

```swift
public protocol EmulatorBackend: Actor {
    static var descriptor: BackendDescriptor { get }
    var state: GuestRunState { get }
    nonisolated var events: AsyncStream<BackendEvent> { get }

    func start(_ request: GuestStartRequest) async throws
    func requestShutdown(timeout: Duration) async     // graceful, with escalation
    func terminate() async                            // immediate
    func recentConsole(limit: Int) -> [String]
}
```

Two things changed from the M1 sketch, both because of what M2 and M3 measured:

- **Snapshots are not on this protocol.** They belong to Milestone 15 and their
  shape depends on qcow2 behaviour we have not exercised. Declaring them now
  would be the same guessing the M1 note warned against.
- **`requestShutdown` does not throw.** There is no useful error: the
  implementation escalates `system_powerdown` → `quit` → `SIGTERM` → `SIGKILL`,
  and the terminal outcome is always "the backend is gone". M3 confirmed the
  first rung genuinely gets ignored, so the ladder is load-bearing.

### Why the coordinator is not an XPC service yet

The M1 plan put the lifecycle coordinator in `MultiemuVMHost.xpc`. That is
deferred to Milestone 17, for a concrete reason: an XPC service must live inside
an app bundle's `Contents/XPCServices/`, and there is no app bundle before M17.

The crash-isolation requirement is already met without it — QEMU is a separate
child process, and Milestone 3 demonstrated that killing it leaves the
application's control state fully intact. What XPC would add is isolation of the
UI from *our own* coordinator, which only matters once a UI exists. Because
`EmulatorBackend` and `EmulatorSession` are already actors with fully `async`
surfaces, inserting an XPC transport later is a wrapper, not a redesign.

---

## State model

```
        ┌──────────┐
        │ inactive │◀──────────────────────────────┐
        └────┬─────┘                               │
   validate  │ resources                           │
        ┌────▼─────┐   backend spawn fails    ┌────┴─────┐
        │ starting ├─────────────────────────▶│  failed  │
        └────┬─────┘                          └────┬─────┘
   backend up │                                    │ recover
        ┌────▼─────┐   boot timeout / panic        │
        │ booting  ├───────────────────────────────┤
        └────┬─────┘                               │
  boot_completed                                   │
        ┌────▼─────┐   backend dies unexpectedly   │
        │  running ├───────────────────────────────┤
        └────┬─────┘                               │
   shutdown  │                                     │
        ┌────▼──────┐                              │
        │ stopping  ├──────────────────────────────┘
        └───────────┘
```

`failed` is a first-class state with a retained reason, not an exception that
unwinds. The application keeps its control state when a backend dies; that is
the entire point of the process split.

**Verified in Milestone 3.** An external `SIGKILL` of the QEMU process produced
`failed(backendTerminatedUnexpectedly)` carrying exit code 9 and 40 retained
console lines, while the session kept its device name, resources, run count and
boot timeline — and restarted successfully into `running`.

Division of responsibility across that boundary:

| | `EmulatorBackend` (per run) | `EmulatorSession` (per device) |
| --- | --- | --- |
| Owns | child process, control socket, boot state machine | configuration, history, policy |
| Lifetime | one run; discarded on failure | the whole device |
| Knows | mechanism | preflight, retry, why the last run died |

The session validates guest image existence itself, because engine-level
validation cannot be trusted to: `VZVirtualMachineConfiguration.validate()`
accepts a kernel URL that does not exist (`VERIFY.md` →
`VZ-VALIDATE-IGNORES-KERNEL-FILE`).

---

## Data layout

```
~/Library/Application Support/Multiemu/
├── config.json                 # application configuration
├── devices/
│   └── <device-uuid>/
│       ├── device.json         # profile: name, image, RAM, storage, display
│       ├── userdata.qcow2      # sparse
│       ├── metadata.qcow2
│       └── snapshots/
├── images/
│   └── <image-id>/
│       ├── manifest.json       # source, version, SHA-256 of every file
│       ├── kernel
│       ├── ramdisk
│       ├── system.img          # read-only, shared between devices
│       └── vendor.img
└── logs/
```

`~/Library/Logs/Multiemu/` holds exported diagnostics bundles.

---

## Threading and concurrency

The package builds in **Swift 6 language mode** with full strict concurrency
checking. Rules:

- Model types (`HostCapabilities`, `BackendDescriptor`, profiles, requests) are
  `Sendable` value types.
- No mutable global state. `MultiemuLog` exposes computed `Logger` values
  precisely so nothing is stored globally.
- Long-lived mutable components (the lifecycle coordinator, backend instances)
  become `actor`s in M3.
- UI state is `@MainActor`; nothing else is.
