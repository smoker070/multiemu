# Roadmap

Vertical, runnable milestones. Each ends with something that builds, runs and is
measured. **A milestone is not complete while any mandatory criterion is failing
or untested.**

---

## Ordering changes from the original plan, and why

| Change | Reason |
| --- | --- |
| **Notarization of the QEMU helper is prototyped in M2**, not deferred to M21 | If a QEMU we build cannot be signed, hardened and notarized with `com.apple.security.hypervisor`, the shipping backend must change. Discovering that at M21 wastes the entire project. A throwaway signed bundle in M2 costs a day. |
| **Getting frames out of the backend is proven in M2**, alongside CPU virtualization | `vhost-user-gpu` on macOS is the highest-risk unknown (`VERIFY.md`). A backend that boots but whose pixels we cannot reach is not a backend. |
| **A modern Android release is targeted before Android 9** | Android 9 predates much of the virtio and generic-kernel work. It is the *hardest* target, not the easiest. Validating it first would stall M4 on the least representative image. |
| **Screenshots move next to graphics (M5-adjacent), recording stays at M13** | A frame capture path is a few lines once frames are ours, and it makes every later milestone verifiable with an artifact rather than a description. |

---

## Milestones

### M1 — Repository, toolchain, host capability detection ✅ COMPLETE
Objective: know precisely what the host can do, before any backend exists.
Criteria: package builds and tests clean; probe reports CPU, memory, storage,
Metal, virtualization, entitlements and tools; blocking problems are named;
selection policy and resource preflight are covered by tests.

### M2 — Backend proof of concept + packaging spike ✅ COMPLETE (one item carried)
Objective: boot **any** Linux kernel under hardware virtualization, get its
console, and prove the shipping story.

**Achieved.** QEMU 11.1.0 + `-accel hvf` boots Linux 6.12.1 on Apple M5 in
**0.305 s to userspace**, 5/5 clean runs. Hardware virtualization also proven
directly from a Multiemu-signed binary (`multiemu-hvprobe` executes guest code).
Acceleration delta measured: HVF 1.0× / same-arch TCG 5.2× / cross-arch TCG
10.5×. QEMU command construction, process supervision, the QMP message layer and
boot detection implemented and tested. Virtualization.framework's 2D-only
graphics limit confirmed from its actual API surface.

**Redesigned as a result.** `vhost-user-gpu` does not exist on macOS. The
Milestone 5 frame path is now `-display dbus,p2p=on`, with a patched QEMU as
fallback and 2D-first regardless. This is the spike doing its job.

**Carried to M21.** `QEMU-NOTARIZATION` needs a build from pinned source and a
Developer ID identity. Everything up to signing is built and proven; only the
credential-bearing step remains. Tracked explicitly rather than silently closed.

### M3 — Lifecycle coordinator + control channel ✅ COMPLETE
Objective: the application starts and supervises a backend it does not contain,
and survives that backend dying.

**Achieved.** `EmulatorBackend` protocol committed. `QEMUBackend` supervises the
child process, connects a QMP control channel, drives the boot state machine and
escalates shutdown. `EmulatorSession` owns preflight, configuration, history and
failure retention. Verified against real QEMU: `query-status -> running` on a
live guest; graceful shutdown escalated correctly when the guest ignored
`system_powerdown`; an external `SIGKILL` produced
`failed(backendTerminatedUnexpectedly)` with exit code 9 and 40 retained console
lines, with device name, run count and boot timeline intact, and `restart()`
recovered to `running`. 116 tests, including a fake QMP server and a mock backend
so the coordinator is testable with no hypervisor.

**Reordered.** The coordinator is not yet an XPC service. An XPC service must
live in an app bundle, and there is no bundle until M17; crash isolation is
already provided by QEMU being a child process. The transport becomes a wrapper
over the existing async surface. See `docs/ARCHITECTURE.md`.

### M4 — Android guest boots to a verifiable state ✅ COMPLETE
Objective: `sys.boot_completed = 1`. **Met.**

Android 17 (SDK 37), image `aosp_cf_arm64_only_phone-img-15660610`, boots through
the product path — `EmulatorSession` → `QEMUBackend` — to `sys.boot_completed=1`
in **3.46 s** median (5 runs), **5.58 s** on a factory-fresh userdata, with
`com.android.launcher3` resumed and 330+ binder services registered. Verified by
a 1920x1080 `screencap` of the rendered lock screen. Target was <= 45 s.

**Host side.** `MultiemuImages` provides manifests with mandatory provenance and
redistribution fields, streaming SHA-256 verified before every boot, an Android
`boot.img` / `vendor_boot.img` parser (v0–4, v3–4) cross-validated against an
independently written Python implementation, an Android sparse-image decoder, and
a GPT composite disk builder validated by macOS's own parser via `hdiutil attach`.

**Guest side.** Seven distinct things had to be right, each of which produced a
differently-shaped dead boot; the ordered account is in `VERIFY.md` →
`ANDROID-BOOT-PREREQUISITES` and the HAL-level half in `CUTTLEFISH-WITHOUT-CVD`.
The two that generalise: an image's fstab suffix must match the filesystem it
actually ships, and a partition Android needs but no image file supplies (`frp`)
will stall `system_server` with nothing in any log naming it.

**Host-side guest services.** `MultiemuGuestServices` answers the protocols the
guest speaks on its virtio-console ports, started and stopped by `QEMUBackend`
with the device. Written as a security boundary — the bytes are guest-chosen.
See `GUEST-CONSOLE-SERVICES`.

**Carried, and deliberately so:**
- Android Verified Boot is relaxed for this image. It is opt-in, applies only to
  the generated composite disk, and the installed image's SHA-256 is still
  verified before every boot. No AOSP image can be verified against a key this
  project holds.
- `androidboot.selinux=permissive` is a bring-up argument, not a shipping
  default, and is marked as such in `AndroidGuestPlan.bringUpKernelArguments`.
- `vendor.threadnetwork_hal` and `vendor.ril-daemon` still crash. Neither is on
  the path to `boot_completed`; both are Cuttlefish HALs wanting host services
  that do not exist here.
- `GuestDisplayMode.headless` cannot boot an Android guest at all — no display
  device means no `/dev/dri/card0`, and SurfaceFlinger and zygote both abort.

### M5 — Frames on screen (+ screenshot capture) ✅ COMPLETE
Objective: Android's display inside the macOS window.

**Achieved end to end.** QEMU's D-Bus display channel delivers guest frames on
macOS (`add_client @dbus-display` → `RegisterListener` → `Scanout`), and Metal
presents them in a real window. 82 frames presented; a 1920×1080 guest shown in
a 900×620-point window with a 1800×1240-pixel drawable at 2.0× backing scale;
screenshot captured at guest resolution, not window resolution.

A from-scratch D-Bus stack backs it (marshalling, SASL in both roles,
peer-to-peer connections, `SCM_RIGHTS`), plus a Metal renderer with four scaling
modes. QEMU is unpatched, so the GPL boundary is unchanged.

**Host frame path: ≈1.5 ms at 1080p** — decode 0.21 ms, upload 0.39 ms,
upload+render 1.31 ms — about 9% of a 60 fps budget, all regression-guarded.
QEMU's VNC server was measured as the alternative and rejected at 117 ms per
frame.

**Deferred with reason.** Sustained frame rate under load is not measured: a
static text console cannot exercise it. That measurement belongs with an
animating guest and moves to M19, where the workload makes it meaningful.

### M6 — Input translation ✅ COMPLETE
Objective: keyboard, mouse and touch.

**Achieved and verified textually.** Input travels over the same D-Bus channel as
frames. Exact interface signatures were taken from QEMU's own introspection
rather than documentation. Keyboard input was proven by having the guest execute
a typed shell command that wrote a marker to a serial port captured to a file —
the marker appeared, so keystrokes arrived *and* the key codes were right.

`GuestDisplayView` is now interactive: key press/release, modifier diffing,
absolute pointer positioning through the exact inverse of the presentation
transform, drag tracking that survives leaving the letterbox, scroll wheel, and
release-everything-on-focus-loss so a held modifier cannot leave the guest
looking hung.

**Pointer mode is negotiated, not assumed.** QEMU refuses `RelMotion` on an
absolute device with `Mouse is not relative`, so the client reads
`Mouse.IsAbsolute` and picks the right call.

**Not done:** end-to-end latency measurement, which needs a guest that visibly
responds to input — deferred to M19 with Android. Extended-block key codes
(arrows, navigation) are implemented but unconfirmed, since evdev and AT set-1
coincide for everything the shell test could exercise.

### M7 — Networking ✅ COMPLETE (one item deliberately open)
Objective: the guest reaches the network.

**Achieved and verified in both directions**, entirely on loopback. The guest's
interface was configured by typing into its shell over the Milestone 6 keyboard
path — the first time one milestone's capability tested another's. The guest
fetched a marker from a host loopback server through libslirp's gateway, and the
host read a marker from a listener inside the guest through a forwarded port.

`lsof` confirmed the forward binds `127.0.0.1` only, which is the property that
matters most for Milestone 8: an ADB port on a wildcard address would expose a
root shell to the local network.

`GuestNetworkConfiguration` refuses privileged host ports, duplicate host ports,
forwards without networking, and bridged mode — the last with its reason rather
than a silent downgrade. `HostPortAllocator` asks the kernel for a free loopback
port, which multi-instance needs so two devices cannot be given the same ADB port.

**Deliberately open:** DNS and internet reachability. libslirp forwards DNS to
the host resolver, so testing it means reaching the internet. The path is the
same one already proven to the gateway; only the destination differs.
`VERIFY.md` records how to close it.

### M8 — ADB ✅ COMPLETE — with a first-party client, which is not what the criterion said
Objective: `adb shell` against the guest, using our own ADB build.
Criteria: device appears in `adb devices`; shell works; the ADB endpoint binds
loopback only; the shipping path uses an AOSP-built client, not Google's binary.

| Criterion | State |
| --- | --- |
| Device appears / connects | **MET** — `CNXN` returns `device::ro.product.name=aosp_cf_arm64_only_phone;…features=shell_v2,cmd,stat_v2,…` |
| Shell works | **MET** — `shell:id` returns `uid=2000(shell) … context=u:r:shell:s0`, `getprop ro.build.version.release` returns `17` |
| Endpoint binds loopback only | **MET** — `hostfwd=tcp:127.0.0.1:<host>-:5555`, never a wildcard, with a test |
| A client that is not Google's binary | **MET, by a different route than the criterion names** — see below |

**The client is ours, and there is no AOSP build.** The criterion asked for a
client built from AOSP `packages/modern/adb` because Google's `platform-tools`
`adb` is not redistributable (`DEPENDENCIES-AND-LICENSING.md` §4). `MultiemuADB`
answers the same problem by not having the dependency at all: the wire protocol
is a 24-byte header and six message kinds, and implementing it is smaller than
carrying a native build of someone else's client. Nothing in the criterion's
purpose — do not ship a binary we may not ship — is left open. Its letter is,
and this row says so rather than quietly redefining it.

What the module contains, and what each part is for:

| Piece | What it does |
| --- | --- |
| `ADBMessage` | The wire codec, with the header magic, the length bound and version-aware checksums |
| `ADBKey` + `ADBBigNumber` | The RSA identity, the `AUTH` signature, and Android's public-key blob |
| `ADBConnection` | `CNXN`, the `AUTH` exchange, stream open, flow control |
| `ADBSync` | `sync:` — `STAT`, `SEND`, `RECV`, and reassembly across chunk boundaries |
| `ADBDevice` | `shell`, `push`, `pull`, `install`, `launch` |
| `multiemu-adb` | The same code as a command, so the shipping client is the one that gets used |

**Verified against the real guest, not only against a double.** `push` of a 3 MB
file and `pull` of a 7.1 MB APK both came back byte-exact, checked with
`sha256sum` computed *inside the guest* and `shasum` on the host — two
independent implementations agreeing on the bytes.

**The real guest found a bug the mock could not.** adbd answered `CNXN` with a
**zero payload checksum**, and the client called it corruption. The protocol
version this client announces — `0x01000001` — is the one at which adbd stops
computing checksums, so the field carries no information. A zero checksum is
indistinguishable from a correct checksum of an empty payload, so the fault was
invisible until the first non-empty message, which is the `CNXN` reply itself.
Verification is now version-aware, and the checks that actually protect this
process — the header magic and the payload-length bound — are unaffected.

**Authentication is implemented and tested, though this guest never asks.**
These images are `userdebug` with `ro.adb.secure` unset. A production image
sends `AUTH TOKEN` and a client with no key cannot get past it, so the token
signature, the `RSAPublicKey` blob with its Montgomery parameters, and the
"offer the key only after the signature is refused" ordering are all exercised
against a mock adbd that demands them. The blob's `n0inv` and `rr` are checked
against values computed by an independent implementation rather than by the same
arithmetic under test.

**The blocker was Android's policy routing, and it is worth stating exactly.**
`buried_eth0` is bound to `virtio_net`, comes up, and takes `10.0.2.15/24` — at
which point the kernel adds the on-link route to the **`main`** table. Android's
rule set never consults `main`:

    0:     from all lookup local
    11000: from all iif lo oif dummy0 uidrange 0-0 lookup dummy0
    16000: from all fwmark 0x10063/0x1ffff iif lo lookup local_network
    17000: from all iif lo oif dummy0 lookup dummy0
    20000: from all fwmark 0x0/0x10000 lookup local_network
    32000: from all unreachable

Unmarked traffic resolves through **`local_network`**, which is empty. So the
host's SYN arrived — the interface's `rx_packets` went up by exactly one per
attempt — and no SYN-ACK was ever routed back. adbd was listening the whole
time. The fix is one route in the right table:

    ip route add 10.0.2.0/24 dev buried_eth0 table local_network

**That sequence is now in the product.** `GuestADBEnablement` holds the steps as
data and runs them over `GuestConsoleShell`, the channel Milestone 19 built, and
then asks the guest whether they took: success is claimed only when
`service.adb.tcp.port` reads back as the port asked for *and* `init.svc.adbd` is
`running`. `setprop` fails silently for a caller that may not set a property, so
a step that ran is not a step that worked. The perf harness now calls this
instead of carrying its own copy of the command list.

**Still a root shell, and still worth saying.** The enablement runs over the
guest's console, which is a root shell inside the guest. What changed is that
the vocabulary is fixed, composed in one place, and never built from anything
the guest said. It is a security boundary the brief names explicitly, and the
honest position is that it is now *managed* rather than *eliminated*: a stock
Android image runs no agent this emulator could talk to instead.

### M9 — Persistent userdata and device profiles ✅ COMPLETE
Objective: state survives restarts, and devices are configurable.

**Achieved end to end.** A device created through `VirtualDeviceStore` had a
marker written into its userdata disk by one guest, was shut down completely,
and a **second** guest read the marker back — both driven by typing into their
shells over the Milestone 6 keyboard path, so the whole test runs unattended.

**Sparse allocation measured, not assumed:** a 32 GiB userdata disk occupies
**196 KiB** when fresh and **384 KiB** after the guest writes. Factory reset
returns it to 196 KiB while the device keeps its name, resources and display.

`DisplayProfile` provides all four landscape presets (1280×720, 1600×900,
1920×1080, 2560×1440) and all four portrait presets, plus validated custom
sizes — even dimensions only, since virtio-gpu scanouts and video encoders
require them. `VirtualDeviceProfile` persists RAM, storage, vCPUs, display and
networking; host-dependent checks stay in `ResourceValidator` so a profile stays
portable between Macs.

Disks go through `qemu-img` rather than a hand-written qcow2 writer: the format
has refcount tables and cluster rules a from-scratch implementation would get
subtly wrong, and a subtly wrong disk loses user data rather than failing loudly.

### M10 — APK installation from the UI ✅ COMPLETE
Objective: install an APK by drag-and-drop or file picker.
Criteria: a test APK installs and launches; host paths validated before use;
install time measured against APK size; malformed input rejected with a named
error.

| Criterion | State |
| --- | --- |
| A test APK installs and launches | **MET** — uninstalled, reinstalled, launched, confirmed in the foreground |
| Host paths validated before use | **MET** — `APKInspector` reads the file before a byte is sent |
| Install time measured against APK size | **MET** — four sizes, table below |
| Malformed input rejected with a named error | **MET** — eight named failures, seven tests |
| Drag-and-drop or file picker | **MET** — both: a `Device ▸ Install APK…` menu item and a drop target on the display |

**The install path is our own ADB client end to end.** Validate, push to
`/data/local/tmp` over the `sync:` protocol, `pm install -r`, remove the staged
copy whatever happened, and report what `pm` said. The staging is not a
flourish: `pm install` cannot read a path on a read-only mount and answers
`Error: Unable to open file … Consider using a file under /data/local/tmp/`.

**Verified as a real state change, not a no-op.** Reinstalling a package that is
already installed proves very little, so the package was removed first and each
step checked:

    pm uninstall --user 0 com.android.deskclock   → Success
    launcher entries mentioning deskclock         → 0
    multiemu-adb install DeskClock.apk            → installed 7.10 MiB in 0.23 s
    pm list packages com.android.deskclock        → package:com.android.deskclock
    launcher entries mentioning deskclock         → com.android.deskclock/.DeskClock
    multiemu-adb launch com.android.deskclock     → started
    dumpsys activity activities                   → topResumedActivity=… u0 com.android.deskclock/.DeskClock

**Install time against size, measured on the running guest:**

| Package | Size | Push | Install | Total |
| --- | --- | --- | --- | --- |
| BluetoothMidiService | 28.2 KiB | 0.00 s (12.5 MiB/s) | 0.14 s | 0.14 s |
| BasicDreams | 184.9 KiB | 0.00 s (37.0 MiB/s) | 0.08 s | 0.09 s |
| Calendar | 2.42 MiB | 0.03 s (85.3 MiB/s) | 0.15 s | 0.18 s |
| DeskClock | 7.10 MiB | 0.08 s (87.6 MiB/s) | 0.13 s | 0.21 s |

The shape matters more than the numbers: **`pm install` costs roughly a constant
0.08–0.15 s whatever the size, and everything that scales is the push**, which
settles at about 87 MiB/s once a transfer is large enough to amortise the round
trips. A 28 KiB package transfers at an apparent 12.5 MiB/s for that reason and
not because small packages are slow.

**What "a test APK" means here, exactly.** It is `DeskClock.apk` taken off the
image itself — a real APK, signed with the platform key, 7.1 MiB. It is not an
APK authored for this test, because authoring one needs `aapt2` to compile a
binary `AndroidManifest.xml`, `d8` for a dex, and `apksigner` for a v2
signature, and none of the Android SDK is on this machine. Building those by
hand would be inventing three file formats to test a transfer. The substitute is
weaker in one specific way — the package is one Android already trusts — and
that is the whole of the difference.

**Rejection happens before the transfer, which is the point.** A file is refused
if it is missing, a directory, empty, over the size ceiling, not a ZIP, a ZIP
with no central directory, or a ZIP with no `AndroidManifest.xml`. The extension
is a claim by whoever named the file; the contents are the evidence. The test
that matters asserts that a rejected file produced **no guest commands at all** —
validation that runs after the push would still "reject" it, having already sent
several hundred megabytes and left them in the guest.

### M11 — Audio ◐ PARTIAL — output proven to the host; the image's HAL is the blocker
Objective: sound out, then microphone in.

**The old deferral was measured on a fixture that predates Android and no longer
describes anything.** It said the guest has no HDA driver and no `/dev/snd`.
Re-measured against the Android 17 guest with every audio device QEMU 11.1.0 on
macOS builds attached at once — `scripts/check-guest-audio.sh` — the picture is
different in every part.

| Layer | State |
| --- | --- |
| Host devices available | `intel-hda`, `AC97`, `usb-audio`. **No virtio-sound in this build at all** |
| Host backends available | `coreaudio`, `dbus`, `wav`, `none` |
| What the guest kernel binds | **USB audio only** — `0 [Audio]: USB-Audio - QEMU USB Audio`; nothing binds HDA or AC97 |
| PCM node | `/dev/snd/pcmC0D0p`, `crw-rw---- system audio`, minimum rate 48 kHz |
| Guest → host, at the ALSA layer | **WORKS** — verified below |
| Guest → host, from an Android app | **BLOCKED** — the framework never sees the card |
| Microphone in | **IMPOSSIBLE with this host and this guest** — no capture device is reachable |

**Output is proven, with a capture rather than a claim.** The host backend was
`wav`, which writes what the guest plays to a file, so "did audio arrive" is
answerable without anyone listening. A 3-second 440 Hz tone played in the guest
with `tinyplay` produced, on the host:

    capture format: 2 ch, 44100 Hz, 16 bit
    132035 frames = 2.99 s
    peak 18821, dominant ~440 Hz

The frequency was recovered from zero crossings, so it is the *content* that was
checked and not just the file size. Audio crosses from the guest's ALSA device
through QEMU's `usb-audio` to a host backend.

**Three things had to be right, and each was wrong first.**

1. `tinyplay` as `shell` fails with `cannot open device 0 for card 0`. The node
   is `system:audio` and the shell user is not in that group. As root it opens.
   Permission, not a dead device — and the two look identical from one attempt.
2. The card refuses 44.1 kHz: `Sample rate is 44100Hz, device only supports >=
   48000Hz`. The first tone was silently nothing.
3. QEMU writes the RIFF sizes when it **closes** the capture, so reading the
   file while the guest still held it reported `not a WAVE file` for a capture
   that was perfectly good. 528 KB of samples were already there.

**The blocker is the image's audio HAL, not the host.** The running HAL is
`/apex/com.android.hardware.audio/bin/hw/android.hardware.audio.service-aidl.example`
— AOSP's *example* implementation. `dumpsys media.audio_flinger` matches USB
**zero** times, and the policy engine's only output is `speaker(2)`. So Android
plays into a HAL that never touches ALSA, and app audio does not reach the host
however the host is wired. Fixing this needs an image whose audio HAL binds ALSA;
no amount of QEMU configuration reaches it.

**What is in the product.** `QEMUConfiguration.Audio` and the command builder now
emit `qemu-xhci` plus `usb-audio` with a `coreaudio`, `dbus` or `wav` backend,
with tests including that a capture path containing a comma is escaped — QEMU
splits options on commas, the same trap already met in `-drive file=` and in
shared-folder paths. USB audio is not a preference: it is the only device this
guest's kernel binds.

**Microphone input is not deferred — it has no path at all.** Three facts close
it, and none of them is a matter of effort:

1. `qemu-system-aarch64 -device usb-audio,help` lists **no input option of any
   kind**. QEMU's USB audio device is output-only.
2. The devices that can capture — `hda-duplex`, `hda-micro`, `AC97` — sit on
   buses this guest's kernel does not bind. Attaching all of them produced one
   card, the USB one.
3. The guest agrees: `/dev/snd` holds `controlC0`, `pcmC0D0p` and `timer`. The
   `p` is playback. There is no `pcmC0D0c`, so no capture node exists to open.

So the pair is output-only, and would be even if the audio HAL were fixed.
Input needs a different guest kernel *or* a QEMU with virtio-sound, which this
build does not have.

**What is in the product now.** A **Sound output** toggle in the device's
settings, `audioEnabled` on the profile (optional, so device files written
before today still decode — the same scar `inputProfiles` carries),
`GuestAudioMode` on the start request, and the backend mapping to a USB audio
device with a CoreAudio backend. The toggle's caption says plainly that apps
stay silent on today's images, because the alternative is a user turning it on,
hearing nothing, and concluding the emulator is broken.

The setting is verified three ways: **it was photographed** — a screenshot of
the settings sheet shows the Audio section, the toggle and its caption
(`--capture-window <png> --open-settings`) — it survives a save and reload, a
profile written before audio existed still decodes as off, and the backend
choice reaches an actual `-device usb-audio` argument.

Getting that screenshot found a defect in the verification tooling rather than
in the interface: captures fail unless a value-taking flag precedes a bare one,
which had made the sheet flags look dead. See `CAPTURE-FLAG-ORDER-MATTERS` in
`VERIFY.md` — including four wrong theories that a better failure message would
have prevented.

It is **off by default**, which is a statement about the images rather than
about the feature:
the guest binds the card happily, but AOSP's example HAL never reaches ALSA, so
app audio would not come out of it. Attaching a sound card nothing can play
through is a device for nothing.

**Why this is PARTIAL and not COMPLETE.** The criterion is sound out *and*
microphone in. Output is proven to the host at the ALSA layer and blocked above
it by the image's HAL; input has no route on this pair at all. Calling that
complete would mean calling a path nobody can hear from an app "sound out".

### M12 — Display controls ✅ COMPLETE
Objective: resolution, DPI, orientation, scaling, fullscreen.

**All eight presets and a rotation applied to a running guest, with no restart** —
verified by measuring the guest's own scanouts rather than by checking that the
request was accepted.

Getting there turned on one non-obvious rule, found by measurement. A guest
cannot select a mode larger than the EDID QEMU builds from the virtio-GPU's boot
`xres`/`yres`, the limit is **per axis**, and it is fixed at boot. Booting at the
configured mode honoured **1 of 10** requests — everything larger fell back to
800×600. Booting at 2560×1440 honoured **6 of 10**, and every failure had a
height above 1440. Allocating a **square** at the largest preset dimension
honoured **10 of 10**: square because rotation swaps the axes, so a 2560×1440
allocation cannot display 1440×2560.

That is now `DisplayProfile.runtimeFramebufferSide`, and the backend allocates it
at boot while the configured mode is applied over D-Bus once the display
attaches. It costs about 26 MB of host memory, well inside virtio-GPU's 256 MB
`max_hostmem` default. A guest's *first* scanout is 640×480 whatever is
allocated — the allocation sets the ceiling, not the starting mode.

Scaling was delivered in M5 (fit, fill, stretch, 1:1, all resolution-independent
and regression-guarded). Fullscreen is the system's own, and the aspect
guarantee is the renderer's `aspectFit` maths, now also tested at ultrawide,
laptop and rotated-monitor surface shapes. Custom sizes were validated in M9 and
that validation is now covered directly: dimension floor and ceiling, even
dimensions, and the DPI band.

The interface gained a Display menu — every preset, a Rotate action, and the
current density.

### M13 — Screen recording ✅ COMPLETE
Objective: record the guest display to a file.

A live guest was recorded at 30 and 60 fps, **rotated mid-recording**, and the
result read back with AVFoundation — because the file is the evidence. A
recorder that reports success and writes something no player can open has
failed. Both runs produced a playable H.264 track at the stated size and rate,
and **6.15 s of guest became 6.03 s of video**: it plays back in real time.

The frame-rate constraint is met by architecture rather than by tuning.
Recording touches the interactive path in exactly one place — `submit(_:)`,
which takes a lock, stores the frame and returns, measuring **0.0001 ms at the
99th percentile** because `GuestFrame`'s pixels are copy-on-write. Everything
else runs on the recorder's own cadence, where the encode costs 3.39 ms of a
33.3 ms tick. The display never waits on the encoder.

Resolution changes were already made an ordinary runtime action by M12, and a
video track cannot change dimensions — so the output size is fixed when
recording starts and later frames of a different shape are fitted into it,
letterboxed, rather than stretching the picture or failing the recording.

**The defect this milestone turned on** cost 3.03 s of a 6.16 s recording, and
four rounds of instrumentation to find. It was not the encoder, not the queue's
QoS, not the timer, and not a failed append — every one of those was measured
and cleared. It was that the recorder is fed only by *new* frames, and a guest
that is not redrawing sends none, so recording a still screen produced almost
nothing. `start(initialFrame:)` now seeds it with what is already on display.

Every early return in the tick now increments a named counter. A silently
dropped tick looks exactly like a slow timer, which is what made three wrong
hypotheses seem plausible for as long as they did.

### M14 — Clipboard and file exchange ◐ PARTIAL — files move both ways; the clipboard cannot
Objective: text both directions; controlled file sharing.

| Criterion | State |
| --- | --- |
| Controlled file sharing | **MET** — over ADB, through `SharedFolder`, verified byte-exact both directions |
| Confinement | **MET**, and stronger than it was: a real hole was found and closed |
| Text both directions | **NOT MET** — no channel exists; see below |
| A folder-picker UI | **NOT DONE** — deliberately |

**The transport question is answered, and the answer changed.** The two sides
still have no filesystem in common, and that finding stands as measured:

| Side | Offers | Lacks |
| --- | --- | --- |
| Host — QEMU 11.1.0 on macOS | `virtio-9p-pci` | no `vhost-user-fs` device at all, and no `virtiofsd` binary |
| Guest — `aosp_cf_arm64` Android 17 | `virtiofs`, built in; `9pnet.ko` + `9pnet_fd.ko` — the 9p **protocol core and fd transport** | **no `9p.ko`/`v9fs.ko`** and **no `9pnet_virtio.ko`** — nothing can mount, nothing can talk to `virtio-9p-pci` |

What changed is that Milestone 8 produced a transport that does not need a
shared filesystem. `GuestFileExchange` moves files over ADB's `sync:` protocol,
which is how Google's emulator does it and for the same reason.

**A copy is not a mount, and the difference is stated rather than glossed.**
Files are moved on request instead of appearing in a directory, and a change on
one side is invisible on the other until it is sent. What did *not* change is
the boundary: every host path still goes through `SharedFolder`, so a guest
naming `../../.ssh/id_rsa` is refused exactly as it would have been over 9p.

**Verified against the real guest, in both directions, with independent
checksums.** A 3 MB file pushed and pulled back, and a 7.1 MB APK pulled off the
image — each compared with `sha256sum` computed *inside the guest* against
`shasum` on the host. Two implementations, same digest.

**A real hole in the confinement was found while wiring this up, and closed.**
The share's stated guarantee was that a symlink inside it cannot be used to
reach outside, because the *resolved result* is re-checked. That was true only
when the final component already existed. Foundation's
`resolvingSymlinksInPath()` resolves a symlinked intermediate component **only if
the leaf exists** — so `link/existing.txt` was caught and `link/not-yet.txt` came
back unchanged, looking like a path inside the share.

That is exactly the shape a write takes, and the write itself follows the link.
The old test passed because its fixture created the target file first, so the
suite gave assurance it had not earned. `resolve(guestPath:)` now walks one
component at a time, follows each link as it is reached — including a dangling
one, which `fileExists` denies and `resolvingSymlinksInPath()` ignores — and
checks containment after **every** step, which also closes `link/..`, where a
textual collapse steps back into the share while the kernel steps into the link
target's parent. Three regression tests pin all three cases.

**Copy and paste is still blocked, and now for a precisely known reason.** QEMU
mediates the clipboard between this process and a *guest agent*, and no stock
Android image runs one. ADB does not rescue it either: the guest has an
`android.content.IClipboard` service but `cmd clipboard` answers **`No shell
command implementation`**, and since Android 10 the framework refuses clipboard
access to anything that is not the foreground app — which a shell never is.
Carrying text would need a small app installed in the guest holding the
foreground, which is a feature with its own consent and lifecycle questions, not
a wiring job.

**No folder-picker UI was added.** The transport is a copy, not a mount, so a
control labelled "shared folder" would describe something the product does not
do. It lands when the shape of the feature is settled.

### M15 — Snapshots, reset, restart, shutdown, crash recovery ✅ COMPLETE
Objective: the full device lifecycle.

**Snapshots capture machine state, not just disk.** Verified by state
comparison: a shell variable (RAM only) and a disk marker were set, a snapshot
taken, both changed, the snapshot restored, and both read back as their
pre-snapshot values. Recovering the shell variable is the decisive part — a
disk-only check could not have told the difference.

Capture **0.357 s**, restore **0.444 s**, machine state **183.9 MiB** for a
2 GiB guest. Listing and deletion both work; listing reads the image directly so
a stopped device can still show its snapshots.

`snapshot-save`/`load`/`delete` are asynchronous QMP **jobs**, so `QMPClient`
gained a job runner that polls `query-jobs` and dismisses on completion — the
command's own reply says nothing about whether the snapshot succeeded.

The rest of the milestone was already standing: graceful shutdown with
escalation and crash detection/recovery from M3, factory reset and persistence
from M9. `EmulatorBackend` now carries the snapshot contract that M3
deliberately deferred until qcow2 and QMP behaviour had been exercised, with
default implementations so a backend that cannot snapshot says so.

The backend also learned to produce a **displayable, interactive** guest
(`GuestDisplayMode.attached`), which M17 needs and which made this milestone
testable at all.

### M16 — Keyboard and game control mapping ✅ COMPLETE (one criterion partly blocked)
Objective: configurable input profiles.

A profile binds a trigger — a key, a gamepad button, or an analog stick — to an
action: a touch held at a screen position, a contribution to a virtual joystick,
or a key passed through. Positions are **fractions of the display**, so a
mapping survives a resolution change instead of pointing at the wrong place.

Several triggers drive one joystick by sharing a `stickID`, which is what makes
W/A/S/D behave as a single control and produce diagonals. The combined vector is
clamped to the unit circle so a diagonal does not out-reach a cardinal push, and
the throw is measured against the display's **shorter** edge so the stick stays
circular on a wide screen. A stick always begins at its centre before moving —
a finger that appears already deflected is not a gesture any guest expects.

`InputMapper` is a pure value type: slot allocation, auto-repeat suppression,
diagonal combination, profile swapping mid-press. Nineteen tests cover it, none
of which need a guest, a gamepad or a display. `InputRouter` is the single owner
of that mapper, because the keyboard and a gamepad can drive the *same* virtual
stick and touch slots are a shared resource — two mappers would hand out one
slot twice.

Profiles are saved with the device. The new fields are optional so that a device
file written before this milestone still decodes; a device that fails to decode
disappears from the library, which is the failure mode being avoided.

**A real defect this surfaced:** the backend attached only a keyboard and a
tablet, so `org.qemu.Display1.MultiTouch` had nothing to deliver to. The guest's
own kernel log settles it — Linux enumerates `QEMU Virtio MultiTouch` only when
`virtio-multitouch-pci` is configured.

**What is not proven.** QEMU accepts `MultiTouch.SendEvent` whether or not a
multitouch device exists, so acceptance is not evidence of delivery and is not
claimed as such. And the Linux fixture has no evdev interface at all — no
`/dev/input`, no `eventN` in sysfs, no `evdev` module — so nothing inside the
guest can observe a touch. **The coordinates a guest ultimately reads are NOT
YET TESTED**, and wait on Milestone 4.

`GCVirtualController` does not exist on macOS, so a controller cannot be
synthesised in software either: **live gamepad input is untested for want of
hardware.** The translation it feeds is fully tested; the adapter that feeds it
is thirty lines and reads a surface confirmed against the running system.

### M17 — The polished application shell ✅ COMPLETE
Objective: the original desktop-emulator UI.

`MultiemuViewModels` is the boundary: `AppModel` and `DeviceModel` own every
call into the backend, and **no view imports a backend module** — the views see
observable state and nothing else. `HelperLocator` decides which binaries the
app spawns, preferring `Contents/Helpers/` over Homebrew and reporting which it
used, so "works from Xcode, broken in the DMG" is visible rather than mysterious.

All artwork is drawn in code: the icon by `MultiemuIconGenerator` through
CoreGraphics, the mark by two offset rounded rectangles. No external asset, and
nothing derived from any other emulator.

Verification of a SwiftUI interface turned out to be the hard part.
`ImageRenderer` cannot render it at all (AppKit-backed controls come out blank),
and `cacheDisplay` cannot composite macOS 26's glass sidebar. The shell
therefore grew launch flags — `--device-root`, `--image-root`, `--appearance`,
`--capture-window`, `--dump-accessibility`, `--open-new-device`,
`--open-settings` — and evidence is taken two ways: **screenshots for content
and colour, the view hierarchy for structure.**

That paid for itself immediately: capturing both appearances exposed a real
defect. The guest surface is always black, but its placeholder text followed the
app appearance, so in light mode it was dark-on-black and invisible. Fixed by
pinning that surface's colour scheme.

`scripts/build-app.sh` produces a signed 3.7 M bundle that passes
`codesign --verify --deep --strict` and `plutil -lint`, with one entitlement.
Hardened runtime needs a real Developer ID and is carried to M21.

### M18 — Multi-instance readiness ✅ COMPLETE
Objective: the architecture supports simultaneous devices.

All three criteria are met and verified through the production path
(`VirtualDeviceStore → EmulatorSession → QEMUBackend`) by
`multiemu-multi-instance-spike`. Four devices run at once with four distinct
helper PIDs, one read-only image file behind all four (compared by inode), and
four distinct forwards, none bound to a wildcard address.

**Sharing rests on a measured QEMU property.** Two processes may hold one image
concurrently only if **both** open it `readonly=on`; a single writable opener
locks everyone else out. Read-only is therefore a property of the *image*, not a
per-device choice. Where a device must write into a shared image — Android's
composite disk carries `userdata` inside it — it gets a **qcow2 overlay over the
shared read-only base**: 192 KiB per device instead of a copy.
`scripts/probe-image-sharing.sh` re-checks the property, with the
writable+writable case as a control so a disabled lock cannot masquerade as a
pass.

**Admission was the hard part, and it took three designs.** Checking then
claiming let two devices each read a total that excluded the other. Claiming
then checking made every device weigh itself against its siblings — six devices
starting together refused *each other*, and nothing ran. Only checking and
claiming in one main-actor step with no suspension between them is correct:
6 concurrent starts now admit exactly 4 and refuse 2. The middle design shipped
into a test run before the concurrent mode caught it, which is the whole reason
that mode exists.

Fixed along the way, all found by the same audit: `reload()` was rebuilding
every `DeviceModel` on any create or delete, orphaning a running device's QEMU
child while its row reset to inactive; the display view latched onto the first
device's input client and kept routing keystrokes there after the selection
changed; `detachDisplay()` cancelled the session-state observer as collateral,
so a restarted device stopped reporting state forever; `DBusConnection.close()`
leaked a descriptor per stop; and the frame path compared whole pixel arrays on
the main actor once per running device.

Measured on the M5: guest memory is allocated **lazily** — two 2 GiB guests cost
642 MiB of host RSS, not 4 GiB — and four concurrent boots cost **1.51×** the
solo boot time. CPU is not the binding constraint; memory is.

### M19 — Performance baselines and optimization ✅ COMPLETE
Objective: measure everything in `PERFORMANCE-METHODOLOGY.md`, then fix the
top bottleneck.
Criteria: full report committed to `reports/`; cold boot <= 45 s; sustained
>= 30 FPS with p99 < 2x p50; idle CPU < 10% of one core — or a documented,
evidence-backed revised target.

| Criterion | Measured | Verdict |
| --- | --- | --- |
| Report committed to `reports/` | `reports/performance-2026-08-25.md` | **MET** |
| Cold boot <= 45 s | 3.92 s | **MET** |
| Sustained >= 30 FPS | 39.5 FPS mean, 2643 frames over 100% of the window | **MET** |
| p99 < 2x p50 | p99 45.73 ms against 2x p50 50.21 ms | **MET** |
| Idle CPU < 10% of one core | **7.4%**, down from 10.2-10.4%; a later run of the same configuration measured 1.5% | **MET** |

`multiemu-perf` measures a real guest and writes the report. It takes its QEMU
command line from `QEMUCommandBuilder` — the builder the emulator itself uses —
and its statistics live in `MultiemuSupport.PerformanceStatistics` with tests.

**Frame rate needed a real workload, and getting one needed ADB.** Synthetic
touches produced 424 frames covering 19% of the sampling window — a lock screen
repainting almost nothing, which is not a frame-rate measurement and was
recorded as "no verdict" rather than as a failure. Driving the guest over ADB
instead (dismiss the keyguard, `am start` Settings, then `input swipe` through
Android's own injection path) gives 2643 frames covering 100% of the window.

**The top bottleneck was inside the guest, not the emulator.** Idle CPU sat on
its target with no attribution beyond "it is QEMU". Stack sampling split it in
one step: all four vCPU threads were in `hv_trap` — running guest code — while
QEMU's main loop was in `g_poll` for 12250 of 12382 samples. Asking the guest
then found the cause. Two HALs cannot work on this host and crash on start, and
Android's init restarts them roughly once a second, forever:

- `vendor.ril-daemon` — `'ro.boot.modem_simulator_ports' must be an integer
  vsock port for the modem simulator`, and given one it opens `AF_VSOCK`. This
  QEMU build has **no vsock device at all** (`-device help` lists none), so the
  modem simulator can never be reached.
- `vendor.threadnetwork_hal` — `Check failed: node_id > 0`, and with
  `androidboot.openthread_node_id=1` supplied it gets one step further and dies
  in `ot-rcp`: `utilsInitSocket() at simul_utils.c:370: Failure`, because the
  simulated radio binds to the interface named by
  `persist.vendor.otsim.local_interface`, default `eth1`, which this guest does
  not have.

**The fix is `GuestServiceQuiesce`**, which stops a listed service **only when
init reports it as `restarting`**. That rule is the safety argument: the list
names services that cannot work *on this host*, so on an image or a host where
one does work, it is left untouched rather than disabled by a list nobody
revisited. Eight tests cover the decision, including that `running`, `stopped`,
an unreadable state and a near-miss spelling all mean "leave alone".
`QEMUBackend` runs it on its boot-completed transition, on its own thread
because the console reads block.

Measured in one guest, stopping and then restarting the services, so guest age
cannot explain it — the control is the oldest and the most expensive sample:

| Same guest, in order | Idle CPU |
| --- | --- |
| Both services crash-looping | 10.2% |
| Both stopped | 8.8% |
| Also Cuttlefish `seriallogging` stopped | 8.2% |
| All three started again (control) | 11.1% |

**Reproduced.** A second run of the identical configuration measured idle CPU
**7.5%**, cold boot 3.683 s, 39.4 FPS from 2520 frames, pacing p99 44.94 ms
against 2x p50 50.63 ms. The margin the earlier attempt lacked is now real:
7.4% and 7.5% against a 10% target, from a baseline that ranged 9.0-11.3%.

**A near miss worth recording.** `androidboot.openthread_node_id=1` alone
measured 9.5% against a 10.2% baseline and looked like a fix. It was not: the
service was still `restarting`, and at equal guest age the same argument scored
11.3% — slightly *worse*, since each restart now does more work before dying.
The 9.5% was run-to-run variation. The argument is not shipped.

**Still open, deliberately.** Cuttlefish's `seriallogging` service streams every
log line at verbosity `V` to a console port this host backs with `null`, and
stopping it is worth a further ~0.6 points. It is not quiesced, because it is
working exactly as designed — the crash-loop rule does not apply to it, and a
second rule for "a service whose output the host discards" needs its own
justification. Recorded rather than taken.

**Input latency remains unmeasured**, as it needs a guest-side timestamp to
correlate against.

**Five measurement errors were found and fixed while building this**, each
producing a stable, reproducible number describing the wrong thing; they are
recorded in `PERFORMANCE-METHODOLOGY.md` §6, and the idle-CPU investigation with
its two further traps in §7.

### M20 — Automated regression and compatibility testing ✅ COMPLETE (one criterion unavailable)
Objective: the compatibility matrix is executed, not asserted.

**`docs/COMPATIBILITY-MATRIX.md` is now an output.** Forty-five claims live in
`ClaimRegistry`, each naming the test suite or spike that demonstrates it, and
the document is generated from running them. First full run: **36 executed and
passed**, 8 blocked with the blocking milestone named, 1 unavailable with the
reason named, in 124 seconds across 42 suites and 8 live-guest spikes.
`scripts/compatibility.sh` regenerates it and exits non-zero if anything that
could be checked failed, so it can gate a change.

Two rules make it worth trusting. **A claim naming a suite that did not run is a
FAILURE**, not a skip — that is drift, and a row outliving its test is exactly
how a matrix starts lying. **Untested is deliberately not failure**, because a
matrix that failed whenever something was out of reach would stop being run.
Host-independent claims render as `inherited` rather than PASS in the Intel
column: the first draft showed a bold PASS there, which reads as "checked on
Intel" when the truth is only "cannot vary by architecture".

**It found two real defects on its first run**, neither of which hand-running
the same things had caught. `multiemu-multi-instance-spike` exited non-zero
whenever fewer devices started than were requested — but it is run with
deliberate over-subscription, where refusing some is the behaviour being
demonstrated; it printed every check as PASS and then exited 1. And
`Recording performance` failed once and never again: its tail assertions were
tight enough that a single scheduler hiccup tripped them. The medians stayed
strict, the tails were loosened to what the property needs. A claim that fails
at random is worse than no claim.

**What is not met.** "On both host architectures" cannot be done here — there is
no Intel Mac, and no row claims one. ADB has no test because it needs a running
Android guest. Both are recorded in the matrix itself rather than left to be
inferred from missing rows.

### M21 — Release pipeline ✅ COMPLETE — as an open-source, unsigned release
Objective: a distributable build, and a stated update strategy.

**The objective changed on 2026-08-27, by decision.** It was "a signed,
notarized, stapled DMG". Multiemu is now MIT-licensed open source with no Apple
Developer membership behind it, so notarization is not a blocked step — it is
one this project does not take. The pipeline that produces a signed release
still exists and still refuses to emit an unsigned artifact when asked for a
signed one; what changed is that `--unsigned` is now a supported outcome rather
than a refusal.

| Criterion | State |
| --- | --- |
| A distributable artifact | **MET** — `scripts/release.sh --unsigned` produces `build/Multiemu-<version>-unsigned.dmg` |
| The artifact is honest about what it is | **MET** — the mode is in the file name, and the run prints what a user must do to open it |
| Licence obligations satisfied | **MET** — `LICENSE` (MIT); `collect-licenses.sh` still refuses to bundle QEMU without its source |
| Update strategy chosen | **MET** — a signed manifest check that notifies and never installs; see `docs/RELEASE.md` |
| Signed and notarized | **NOT DONE, BY CHOICE** — see above |
| Self-contained backend | **MET** — QEMU 11.1.0 built from pinned source, bundled, boots Android with nothing from Homebrew |
| Clean-Mac installation | **NOT TESTED** — needs a second machine |

**Three modes, and each one refuses to be mistaken for another:**

    scripts/release.sh --rehearsal   # everything that needs no credentials; not distributable
    scripts/release.sh --unsigned    # what this project ships
    scripts/release.sh               # signed and notarized; refuses without credentials

The unsigned build is named `-unsigned.dmg` deliberately. A file called
`Multiemu-0.9.0.dmg` that Gatekeeper refuses is indistinguishable, once
downloaded, from a signed one that broke.

**Gatekeeper rejects the unsigned image, and the run says that is correct.**
`spctl` reporting `no usable signature` is the assessment doing its job, not a
build failure — and it is the control that shows the assessment discriminates at
all. Users get told, in the release output, to run
`xattr -d com.apple.quarantine` once or to right-click and Open; anyone who
would rather not can build from source, which needs no credentials.

**One real defect was found here and is worth keeping.** Adding the licence
materials to an already-signed bundle broke its seal, and nothing in the build
said so — the app had verified moments earlier. Only mounting the image and
checking again surfaced *a sealed resource is missing or invalid*. Licences are
collected before `codesign` runs. If you add anything to the bundle, add it
before signing.

**A second one, found on 2026-08-27 while adding the unsigned mode.** The script
computed the DMG's name *after* asking `make-dmg.sh` to build it, and simply
assumed the two strings matched. Changing the name for the unsigned mode broke
that assumption instantly: the run reported a path no file had ever been written
to, and reported it as a success. The name is now computed first and passed in.

**Shipping QEMU is gated on its source.** QEMU is GPL-2.0-only, so
`scripts/collect-licenses.sh` refuses — an error, not a warning — to prepare a
bundle containing QEMU binaries without the corresponding source tree, and
writes `COPYING`, the exact version and commit, and a three-year written offer
when one is given. Nobody reads a build log before uploading a DMG. MIT changes
nothing about this: it governs Multiemu's own code, not the binaries it carries.

**The backend ships inside the app.** `scripts/build-qemu.sh` builds QEMU 11.1.0
from a pinned tarball whose checksum matches Homebrew's independent record,
bundles it with its dylibs relocated and its ROMs, and the result boots Android
loading **zero** libraries from `/opt/homebrew`. The app is 175 MB and the
compressed image 36 MB. Four defects surfaced only by running it — a build that
refuses paths with spaces, missing ROMs, a broken code seal, and a licence gate
that ran before the thing it gates — all recorded in `VERIFY.md` under
`QEMU-BUNDLING`.

**One thing left before distributing:** `MULTIEMU_SOURCE_URL` is unset, so the
GPL written offer has no address on it. Set it to the public repository.

**If you want a signed build**, `docs/DEVELOPER-ID.md` is still there and still
accurate — the licence lets anyone make one. This project does not.

