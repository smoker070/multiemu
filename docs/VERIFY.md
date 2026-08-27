# Verification log

Version-sensitive claims this project depends on. Each is either **OPEN** (must
be confirmed before it is relied on) or **CONFIRMED** with the evidence that
closed it.

Host used for confirmations unless noted: **Apple M5 (Mac17,3), macOS 26.5.2
build 25F84, 16 GiB, Xcode 26.6 / Swift 6.3.3.**

---

## Milestones 8, 10, 11 and 14 — 2026-08-25

### `ADB-CHECKSUM-IS-ZERO` — CONFIRMED 2026-08-25
Real `adbd` sends a **zero payload checksum**, and a client that verifies it
rejects the guest's own `CNXN` reply.

The protocol version this client announces, `0x01000001`, is the one at which
adbd stops computing checksums. The field is then meaningless. This was not
visible against a mock — the mock computed correct checksums — and not visible
on an empty payload either, because a zero checksum is a *correct* checksum of
nothing. The first non-empty message is the connect banner, so the failure
arrived as `ADB payload checksum 43886 does not match the announced 0` on the
very first exchange with the real guest.

Verification is now version-aware. The checks that protect this process — the
header magic, which catches a desynchronised stream at once, and the
payload-length bound, which stops a guest making this client allocate without
limit — are unaffected and still unconditional.

*Evidence:* `multiemu-adb --port 15555 info` against Android 17, failing before
the change and returning
`device::ro.product.name=aosp_cf_arm64_only_phone;…features=shell_v2,cmd,stat_v2,…`
after it.

### `ADB-FILE-TRANSFER-IS-BYTE-EXACT` — CONFIRMED 2026-08-25
The `sync:` implementation moves files unchanged in both directions.

Checked with two independent implementations rather than by re-reading what we
wrote: `sha256sum` **inside the guest** against `shasum -a 256` on the host.

| Direction | File | Digest (first 32) |
| --- | --- | --- |
| host → guest | 3,000,000 random bytes | `df9eb16352767916ce59e3b08ab5e723` |
| guest → host, same file back | | `df9eb16352767916ce59e3b08ab5e723` |
| guest → host | `/product/app/DeskClock/DeskClock.apk`, 7,449,572 bytes | `ded49b00e5045bdd184c2a4f09b1b865` |

Push settles at about 87 MiB/s once a transfer is large enough to amortise the
round trips.

### `APK-INSTALL-END-TO-END` — CONFIRMED 2026-08-25
An APK installs through this project's own client and the app then runs.

The package was **removed first**, because reinstalling something already
installed proves almost nothing:

    pm uninstall --user 0 com.android.deskclock   → Success
    launcher entries mentioning deskclock         → 0
    multiemu-adb install DeskClock.apk            → installed 7.10 MiB, push 0.08 s, install 0.13 s
    pm list packages com.android.deskclock        → package:com.android.deskclock
    launcher entries mentioning deskclock         → com.android.deskclock/.DeskClock
    multiemu-adb launch com.android.deskclock     → started
    dumpsys activity activities                   → topResumedActivity=… u0 com.android.deskclock/.DeskClock

`pm install` also refuses a path on a read-only mount —
`Error: Unable to open file … Consider using a file under /data/local/tmp/` —
which is why the client stages the package before installing rather than
pointing `pm` at a path the guest can already see.

### `GUEST-AUDIO-REACHES-THE-HOST` — CONFIRMED 2026-08-25
Audio played in the guest arrives on the host, through `usb-audio`.

Of the three audio devices QEMU 11.1.0 on macOS builds — `intel-hda`, `AC97`,
`usb-audio`; there is no virtio-sound — this guest's kernel binds only USB
audio. All three were attached at once and the guest asked what it enumerated:
one card, `0 [Audio]: USB-Audio - QEMU USB Audio`, with `/dev/snd/pcmC0D0p`.

A 3-second 440 Hz tone played with `tinyplay` and captured by the `wav` backend:

    capture format: 2 ch, 44100 Hz, 16 bit
    132035 frames = 2.99 s
    peak 18821, dominant ~440 Hz

The frequency was recovered from zero crossings, so the *content* was checked
and not merely the file size.

Three false negatives came first, each looking like "audio does not work":
`tinyplay` as `shell` cannot open a `system:audio` node (root can); the card
refuses rates below 48 kHz (`device only supports >= 48000Hz`); and QEMU writes
the RIFF sizes only when it closes the capture, so reading it while the guest
still held it reported `not a WAVE file` for 528 KB of perfectly good samples.

**Still blocked above that layer:** the image runs AOSP's *example* audio HAL,
`dumpsys media.audio_flinger` matches USB zero times, and the policy engine's
only output is `speaker(2)`. App audio does not reach the host on this image,
and no host configuration changes that.

### `THE-APP-COULD-NEVER-BOOT-ANDROID` — THREE DEFECTS, FIXED 2026-08-28
Every CLI and script in this project booted Android. The application never
could, and for three independent reasons — each of which alone was fatal, and
none of which any CLI could hit because the CLIs supplied the missing pieces by
hand.

| # | Defect | Symptom |
| --- | --- | --- |
| 1 | `AndroidGuestPlan` never set `consolePorts` | stalls in second-stage init until the 180 s timeout |
| 2 | The installed image had **no** `requiredKernelArguments` | no `androidboot.*` at all |
| 3 | `layout` defaulted to `.separateBlockDevices` and **nothing ever set it** | kernel panic at ~10 s: `Attempted to kill init! exitcode=0x00007f00` |

The third only became visible once the first two were fixed. Cuttlefish mounts
through `/dev/block/by-name/…`, which exists only on one GPT disk; presented as
a block device per partition, first-stage init finds nothing to mount and takes
the kernel down with it. The enum's own comment had said so since it was
written — *"This is what Cuttlefish-style images assume"* — and no code path
ever selected it.

`partitionLayout` is now a manifest field, detected at install for a recognised
board, and the plan takes the image's answer over its own default.

**Verified by booting from the application itself**, not from a script: a
`--start-device` flag starts the first device and reports state transitions to
stderr, because the activity log lives in the window and a headless run is
otherwise blind. Progression observed: `kernelStarted 0.16 s` → vold and
keystore2 → apexd loading pre-installed APEXes at 1.1 s → **state: Running**.

*Why a flag was needed at all:* the bug lived exclusively in the interface path.
Every existing verification tool passed console ports and kernel arguments
explicitly, so all of them booted a guest the application could not.

### `IMAGE-STATES-ITS-OWN-BOOT-REQUIREMENTS` — CONFIRMED 2026-08-27
An installed image is now read for the kernel arguments it needs, instead of a
person remembering to pass them.

Installing without them produced a guest stalled in second-stage init until the
timeout, reported by the user as **"the emulator is booting very very slowly"**.
It was not slow. It was stuck, and the 180 s was the timeout.

**What is derived, and from what:**

| Answer | Evidence |
| --- | --- |
| Board `cutf_cvm` | `ueventd.cutf_cvm.rc` in the ramdisk — Cuttlefish names init scripts after the board, so the name is *in* the file name |
| `userdata` is **f2fs** | the f2fs superblock magic at offset 0x400 of the expanded image |
| fstab `cf.f2fs.cts` | of the four variants the ramdisk ships, the f2fs ones match the image; `cts` is a stated default, not a detection |
| HAL selections | added only for a board this project has actually booted |

**Two things it refuses to do.** It will not choose an fstab when no variant
matches the filesystem — a wrong suffix does not fail, it hangs at first-stage
mount. And it will not give an unrecognised board Cuttlefish's HAL arguments.

**Reading the ramdisk needed real decompression, and a shortcut was rejected on
evidence.** A raw byte scan of the compressed ramdisk found
`ueventd.cutf_cvm.rc` and a *truncated* `fstab.cf.ext4.c`, and missed the f2fs
variants entirely — parts of a compressed stream survive as plain text and parts
do not. That detector would have chosen the ext4 fstab for an f2fs image.

The ramdisk is LZ4 **legacy** framed (magic `0x184C2102`): a bare repeating
`[uint32 LE compressed size][block]` with no frame descriptor. Verified against
the file itself — the block chain consumes exactly 21,808,480 bytes, all of it —
and decoded with `COMPRESSION_LZ4_RAW` from Apple's Compression framework, so no
dependency was added. Entry names come from parsing cpio `newc` headers, not
from pattern-matching.

**The file contains two concatenated frames**, because this project writes the
vendor ramdisk followed by the generic one. A decoder that stopped at the first
would have returned a plausible tree missing exactly the half that carries the
fstabs.

**And the cpio walk had the same bug one level up — found by review, after it
had shipped.** One LZ4 frame is one cpio archive, so the stream holds two
archives, and the walk stopped at the first `TRAILER!!!`. It returned **522 of
559** entries and looked entirely successful. The test that let it through
asserted `count > 100`.

Tightened to the exact count, measured independently by piping `lz4 -d -c`
through a cpio header walk: **559 entries, 2 trailer records, 48,194,048 bytes
decompressed**. A trailer now ends its archive rather than the file.

*Why a byte scan cannot substitute even here:* `TRAILER!!!` occurs **four** times
in the decompressed stream and only two are records. The other two sit inside a
binary's string table — `070701%040X%056X%08XTRAILER!!!%c%c%c%c`, toybox's own
cpio writer. Counting the string reports four archives. Both cases are pinned by
tests built from synthetic newc records.

*Caveat recorded in the code:* `compression_decode_buffer` cannot distinguish a
too-small destination from corrupt input. That is safe only because the legacy
format caps a block at 8 MiB and the destination is exactly that size.

### `KERNEL-ARGUMENTS-SPLIT-IMAGE-FROM-MACHINE` — CONFIRMED 2026-08-27
The arguments were split by who actually knows them, and the split is tested to
be complete.

* The **image** knows its board, its fstab and which HALs it ships — 11
  arguments, in its manifest.
* The **emulator** knows which console port it wired, its machine's PCIe
  address, that it relaxed verified boot, and which slot it built — 14
  arguments, in `AndroidGuestPlan`.

Their union is **exactly** the command line this project has booted Android 17
with: nothing missing, nothing extra, asserted by test. Writing the machine half
into an image manifest would have worked and been wrong — the same image on
another host would carry another host's facts.

### `QEMU-BUNDLING` — CONFIRMED 2026-08-27 — closes the last open shipping question
QEMU 11.1.0 builds from pinned source, bundles into the app, and boots Android
with nothing from Homebrew.

| Step | Result |
| --- | --- |
| Source | `qemu-11.1.0.tar.xz`, sha256 `6ee1d1a6…fa858` — **matches Homebrew's independently recorded checksum** for the same tarball |
| Configure | `dbus_display: enabled`, `hvf: enabled`, `coreaudio`, `slirp`; cocoa/sdl/gtk/vnc/spice disabled |
| Devices | every device the product uses is present, identical to the Homebrew binary; only `cocoa` differs, by intent |
| Self-containment | `DYLD_PRINT_LIBRARIES` loads **zero** libraries from `/opt/homebrew`; all 20 dylibs resolve inside the bundle |
| Android boot | boots, and the driver inventory matches the Homebrew control **exactly** (9p no, virtiofs yes, virtio interface yes, vsock yes) |
| Size | app 175 MB, compressed DMG **36 MB** |

**Four defects were found by running it, none of which any static check saw.**

1. **QEMU refuses to build under a path containing a space.** `ERROR: main
   directory cannot contain spaces nor colons`, and this project's path has
   three. The build now happens under `/tmp/multiemu-qemu`; the tarball stays in
   `vendor/` because that is the source we are obliged to publish.
2. **Missing data files.** The binary linked cleanly, reported its version, and
   died on the first real machine with `failed to find romfile
   "efi-virtio.rom"`. QEMU's ROMs and firmware were never copied. They now go to
   `Contents/share/qemu`, where QEMU finds them with no runtime flag.
3. **A broken seal.** Adding the backend after `build-app.sh` had signed the app
   invalidated its signature — caught by the mount-and-verify step with *a
   sealed resource is missing or invalid*, the same failure this pipeline
   recorded once before for licence files. The app is now re-signed after the
   backend goes in.
4. **A compliance gate that ran before the thing it gates.** `collect-licenses.sh`
   ran inside `build-app.sh`, when `Contents/Helpers` was still empty, so it
   wrote a notice saying *"This build bundles no third-party binaries"* — and
   then three QEMU binaries and 92 MB of its ROMs arrived. The GPL source
   requirement went unchecked and the shipped notice was false. The gate now
   runs after bundling; asked to check the real bundle without a source tree it
   refuses outright, as designed.

*Diagnosing (2) needed a fifth fix:* `check-guest-drivers.sh` stopped watching
whether QEMU was alive once its socket appeared. QEMU creates `-chardev
socket,server=on` listeners before validating later options, so a QEMU that died
immediately looked like a guest that booted slowly, and the explanation sat
unread because the script also sent QEMU's output to `/dev/null`. It now watches
the process and prints QEMU's own words.

*Still open before distributing:* `MULTIEMU_SOURCE_URL` is unset, so the GPL
written offer carries no URL. It needs the public repository address.

### `CAPTURE-FLAG-ORDER-MATTERS` — CONFIRMED 2026-08-27 — **corrects an earlier entry**
Interface captures work, including of sheets. An earlier version of this file
claimed the opposite; that claim was wrong and is withdrawn.

The rule: **a flag that takes a value must come before a bare flag.**

| Command | Result |
| --- | --- |
| `--open-settings --dump-accessibility <path>` | no window is ever created; the dump finds nothing |
| `--dump-accessibility <path> --open-settings` | **dumps the sheet** |
| `--capture-window <png> --open-settings` | **screenshots the sheet**, form and all |
| `--dump-accessibility <path>` alone | works (which is why this went unnoticed) |

Both orders parse identically inside the app — `overrideRoot(for:)` finds the
same path either way — so the difference is in AppKit. The likely cause is the
user-defaults argument domain, which reads `-key value` pairs: with the bare
flag first, `--dump-accessibility` is taken as the *value* of `-open-settings`
and the path is left as an orphan argument, which the app then appears to treat
as something to open. That last step is inferred, not measured; the ordering
rule is measured.

**How it was found, and why it took four attempts.** Every run had been written
in the broken order, so the sheet flags looked dead. Each failure produced the
bare message `accessibility dump failed`, which cannot distinguish "no window
exists yet" from "windows exist but none is visible" from "one is visible but
not key" — and those have opposite causes. Four theories were tried and
discarded on that evidence: a modal run-loop mode, statement order inside
`onAppear`, scheduling from `App.init()`, and sheets being uncapturable in
principle. Making the failure print `windowSummary()` instead — window count,
titles, visibility, key status, frames — named the problem on the next run:
`no windows exist at all`.

*Consequence:* the only lasting change is that diagnostic, plus a bounded retry
so "not up yet" is not mistaken for "never coming". Everything else attempted
was reverted. `--open-settings` and `--open-new-device` are not dead and never
were.

### `SETTINGS-FORM-INCLUDING-AUDIO-IS-BUILT` — CONFIRMED 2026-08-27
The device settings form renders with its audio control.

Captured with `--capture-window <png> --open-settings` against a real device
store. The screenshot shows, in order: **Name** (`Android Device`),
**Resources** (Memory `3.00 GiB` with its slider, Processors `4` with its
stepper), **Display** (Resolution `720 × 1280`), and **Audio** — a `Sound
output` toggle, off, above the caption that says apps stay silent on today's
images.

The accessibility dump of the same run is structurally distinct from the main
window's, and its window frame is **520x600** — exactly the size written in
`DeviceSettingsSheet`'s own `.frame(width:height:)`:

| | Sheet dump | Control (main window) |
| --- | --- | --- |
| Frame | **520x600** | 1180x760 |
| Split views | 0 | 2 |
| List rows | 0 | 3 |
| Focus rings | 10 | 2 |

That is the second, independent confirmation that the form is what was
captured — but only after the defect below was fixed. Before it, the dump of
the same command described the main window instead.

### `DUMP-WALKED-THE-WRONG-WINDOW` — DEFECT FOUND AND FIXED 2026-08-27
`AccessibilityDump` reported a sheet capture as a success while describing the
sheet's **parent**.

`WindowCapture` had always preferred `window.attachedSheet`, with a comment
saying that capturing the parent instead "would silently produce a screenshot
of the wrong thing". `AccessibilityDump`, its sibling in the same directory
doing the same job in text, never got that line.

*Found by:* comparing a `--open-settings` dump against the control dump rather
than reading it on its own. They were identical — two split views, three list
rows, 1180x760 — while the screenshot from the same run plainly showed the
settings form. A dump that had described the wrong window and called it a
success.

*Why it matters more than a failed capture:* a failure is visible. This
returned a well-formed file, exited zero, and would have been quoted as
evidence for whatever the reader assumed it showed. It very nearly was — an
earlier draft of the entry above cited it as independent confirmation of the
settings form.

*Fixed:* the dump now prefers the attached sheet, and the sheet's own frame
(520x600) is what distinguishes it. The non-sheet path is unchanged and still
reports 1180x760.

### `BLIND-FAILURES-SWEPT` — DONE 2026-08-27
The rest of the project's verification programs were checked for the same
defect: a failure message that discards state the reader cannot otherwise see.

| Site | Was | Now |
| --- | --- | --- |
| `WindowCapture` | `window capture failed` for five different causes | names which one, with window title and size |
| `socketpair failed` x4 spikes | no `errno` at all | `strerror(errno)` |
| Persistence spike | `the first guest run did not start` | the serial log's path and its last eight lines |
| Network spike | `network configuration is invalid` | **left alone** — the problems are printed one line above, so nothing is hidden |

The last row is the point of the exercise: the test is whether state is being
*discarded*, not whether a message is terse. A message that is short because
the detail is already on screen is fine.

### `GUEST-AUDIO-INPUT-HAS-NO-PATH` — CONFIRMED 2026-08-25
Microphone capture is not reachable with this host and this guest, and the
reason is structural rather than unfinished work.

- `-device usb-audio,help` lists no input option at all. QEMU's USB audio
  device is output-only.
- The capture-capable devices (`hda-duplex`, `hda-micro`, `AC97`) sit on buses
  this guest's kernel does not bind — attaching all of them yielded one card,
  the USB one, and only `virtio-pci` and `xhci_hcd` were bound to PCI devices.
- The guest's own node list settles it: `/dev/snd` holds `controlC0`,
  `pcmC0D0p`, `timer`. `p` is playback; there is no `pcmC0D0c`.

Two independent sides agree, which is what makes this a conclusion rather than
a failed attempt.

### `SHARED-FOLDER-DANGLING-SYMLINK` — CONFIRMED AND FIXED 2026-08-25
The share's confinement had a hole, and the existing test could not see it.

`SharedFolder.resolve(guestPath:)` re-resolved the result and checked
containment, which is the right idea. But Foundation's
`resolvingSymlinksInPath()` resolves a symlinked **intermediate** component only
when the final component exists. Measured directly:

    escape_real/secret.txt  =>  <share>/escape_real/secret.txt      (unchanged — NOT resolved)
    escape_real             =>  <outside>/…                          (resolved)

So a guest-supplied name for a file that does not exist yet came back looking
like it was inside the share — and that is precisely the shape a *write* takes,
with the kernel following the link.

The existing symlink test passed only because its fixture created the target
file first. It gave assurance it had not earned.

`resolve` now walks one component at a time, follows each link as it is reached
including a dangling one, and checks containment after **every** step. That last
part also closes `link/..`, where a textual collapse steps back into the share
while the kernel steps into the link target's parent. Three regression tests pin
the three cases.

### `ANDROID-CLIPBOARD-HAS-NO-SHELL-ROUTE` — CONFIRMED 2026-08-25
Carrying clipboard text over ADB is not available on a stock image.

The guest publishes `android.content.IClipboard` (`service list` shows
`121 clipboard`), but `cmd clipboard` answers **`No shell command
implementation`**, and since Android 10 the framework refuses clipboard access
to anything that is not the foreground app — which a shell never is. QEMU's own
clipboard mediation needs a guest agent that no stock Android image runs. Text
in either direction needs an app installed in the guest, not more wiring.

---

## Milestone 4 (Android guest) — 2026-08-20

### `ANDROID-IMAGE-DOWNLOAD-URL` — PARTLY CLOSED 2026-08-20
Open since Milestone 4. Two of its three unknowns are now settled from Android's
own documentation and a published artifact link; the third is not.

**The target name was wrong.** There is no `aosp_cf_arm64_phone` on current
branches. The arm64 Cuttlefish target is:

    aosp_cf_arm64_only_phone-userdebug

on branch `aosp-android-latest-release` (or `aosp-main-throttled`, with
`?legacy=1`). Note `_only_` — the 64-bit-only variant. This is why the target
could not be found on the `aosp-main` grid: arm64 Cuttlefish is not built there.

**The URL shape is confirmed**, from a real published artifact link of the form

    .../builds/submitted/<build-id>/<target>/latest/<artifact>

which is exactly what this project's script constructs.

**The artifact name is still unconfirmed.** Android's own pages give it two ways
— `aosp_cf_arm64_only_phone-<id>.zip` in one place and the glob
`aosp_cf_*img*.zip` in another. The script now tries `<product>-img-<id>.zip`
and `<product>-<id>.zip`, reports which names it tried, and tells the reader to
take the link from the Artifacts tab if neither works. Guessing once and failing
with a bare 404 was the failure mode being removed.

*Closes when a download actually completes.* Nothing here has been exercised
against the network; all of it is read from documentation.

**Also settled:** `cvd-host_package.tar.gz` is **not** needed. It carries
Cuttlefish's own Linux launcher, and this project builds the composite disk and
boots the images itself — which is why the GPT composite builder exists at all.

**A defect this exposed.** The script took an optional target argument but
hardcoded the artifact name to the Cuttlefish x86 pattern, so passing any other
target silently produced a wrong URL and an unexplained 404. The name is now
derived from the target, and a non-Cuttlefish product warns before downloading.

### `NO-IMAGE-CAN-BE-OBTAINED-FROM-THIS-ENVIRONMENT` — CONFIRMED 2026-08-20 — **M4 blocker**
Not a `ci.android.com` problem specifically: **all external network egress from
this environment requires human approval**, so no image can be downloaded from
anywhere.

```
RUNTIME_FLOOR:egress: runtime action hard floor:
external network egress requires human approval
```

Checked for an image already on the machine as well — no Android SDK, no
`system-images`, no `.img` artefacts anywhere. There is nothing local to use.

`scripts/fetch-android-image.sh` is written, records a SHA-256 of exactly what
it downloaded, extracts, and prints the precise `multiemu-image` commands that
follow. It is the one step that needs a person.

### `THE-BOOT-PATH-IS-NOW-WIRED` — CONFIRMED 2026-08-20 — **M4, partial**
Until now `AndroidGuestPlan` was referenced by nothing outside its own file and
its tests: starting a device built a request with **no kernel at all**, so the
application could not have booted an image even if one were installed.

`DeviceModel` now builds its start request from the installed image set — kernel,
ramdisk, command line, and partitions attached with per-device overlays over the
shared read-only image. A device whose image is not installed fails immediately
with the image named and how to install it, rather than starting a kernel-less
guest that fails as a boot timeout three minutes later.

**This is wiring, not a boot.** Nothing has booted Android, and this claim says
only that the path exists and is reachable.

### `OVERLAY-IDENTITY-MUST-BE-VERIFIED` — CONFIRMED 2026-08-20 — defect found and fixed
`ensureOverlay` adopted any file already at the overlay path. Overlay names are
derived from the source's filename, so two different bases can want the same
overlay name — and a base that was replaced leaves an overlay pointing at
something else. Adopting blindly is how a device silently boots the wrong disk.

It now reads the overlay's actual `backing-filename` from `qemu-img info` and
refuses unless it resolves to the requested base. Three tests: a matching
overlay is reused, one backed by a different image is refused, and a plain qcow2
sitting where an overlay belongs is refused.

### `THE-COMPOSITE-DISK-WAS-KEYED-TOO-LOOSELY` — CONFIRMED 2026-08-20 — defect found and fixed
`composite.img` was one file per image set, but its layout depends on the
**userdata size** and the **A/B slot**, both of which are per device. A device
configured for 64 GiB could adopt a 32 GiB disk built for another: the file
exists, so it was reused, and nothing reported the mismatch.

The name now carries both — `composite-_a-32g.img` — so different configurations
cannot collide and the same configuration still finds its own disk, which is
what makes userdata survive a restart.

### `THE-COMPOSITE-BUILD-RACED-ITSELF` — CONFIRMED 2026-08-20 — defect found and fixed
Building writes the file at the *start* and then streams gigabytes into it. A
second device starting meanwhile found a partially written disk, decided it was
"already present", and would have booted a truncated image.

It now builds to a private staging path and publishes with `link`, which fails
with `EEXIST` rather than overwriting — so whichever device finishes first wins
and the other adopts its result. No lock file, and therefore nothing to go stale
if a build is killed.

*Not changed:* the unpacked boot files (`kernel`, `dtb`, `ramdisk`) were already
written with `.atomic`, so that race was already handled. Recorded rather than
"fixed", because they were not broken.

---

## Confirmed in Milestone 21 (release pipeline)

### `THE-PIPELINE-RUNS-END-TO-END-WITHOUT-CREDENTIALS` — CONFIRMED 2026-08-20 — **M21 acceptance (in part)**
`scripts/release.sh --rehearsal` exercises every step that does not need Apple
credentials and names the three that do. On this host:

| Step | Result |
| --- | --- |
| Preflight, tests, build, signature report | ran |
| Notarize and staple the app | **skipped — no notary credentials** |
| Disk image: build, verify checksum, mount, verify the app inside | ran |
| Sign the disk image | **skipped — no Developer ID** |
| Notarize and staple the image | **skipped — no notary credentials** |
| Gatekeeper assessment | ran |

Without `--rehearsal` the script **refuses** rather than emitting an unsigned
DMG: something that looks like a finished release and behaves like a broken one
is worse than a failed build.

### `GATEKEEPER-REJECTS-AN-AD-HOC-BUILD` — CONFIRMED 2026-08-20
`spctl -a -vvv` **rejects** both the ad-hoc app and the unsigned image
(`source=no usable signature`).

That rejection is the **control**. It is the expected result for a build with no
Developer ID, and it is what shows the assessment is checking something rather
than passing everything put in front of it. A pipeline that reported success
here would be reporting nothing.

`security find-identity -v -p codesigning` returns **0 valid identities**, so
Developer ID signing, the hardened runtime and notarization are all unexercised
— not merely untested but unreachable.

### `LICENCES-MUST-BE-COLLECTED-BEFORE-SIGNING` — CONFIRMED 2026-08-20 — defect found and fixed
Adding `Contents/Resources/licenses/` to an already-signed bundle broke its
seal. The disk-image step caught it:

```
/Volumes/Multiemu 0.9.0/Multiemu.app: a sealed resource is missing or invalid
the app inside the image FAILS its signature check
```

The app had verified moments earlier, before the licences were added. Nothing in
the build reported a problem — the failure only appears when something verifies
the bundle again, which in a release is on a user's Mac.

*Fix:* `build-app.sh` collects licences **before** `codesign`, so the signature
covers them. The disk-image step keeps mounting the image and re-verifying the
bundle inside, because that is what caught it.

### `SHIPPING-QEMU-IS-GATED-ON-ITS-SOURCE` — CONFIRMED 2026-08-20
QEMU is GPL-2.0-only, and distributing the binary obliges us to provide the
corresponding source. `scripts/collect-licenses.sh` **refuses** — exit 65, not a
warning — to prepare a bundle containing QEMU binaries without a source tree:

```
REFUSED: this bundle contains QEMU binaries in Contents/Helpers, but no QEMU
source tree was given.
```

Verified by placing a file named `qemu-img` in `Contents/Helpers` and observing
the refusal. When a source tree is given it writes `COPYING`, a
`SOURCE-VERSION.txt` recording version/commit/describe, and a three-year written
offer naming where the source is published — because "a recent QEMU" is not what
the licence asks for.

A warning would have been the wrong design: nobody reads a build log before
uploading a DMG.

---

## Confirmed in Milestone 20 (the matrix is executed)

### `THE-MATRIX-IS-GENERATED-FROM-RESULTS` — CONFIRMED 2026-08-20 — **M20 acceptance**
`docs/COMPATIBILITY-MATRIX.md` is now an **output**. Every row is produced by
running the evidence named for it in `ClaimRegistry`, and the document says so
at the top.

First full run, on the development host:

| | |
| --- | --- |
| Claims | **45** |
| Executed and passed | **36** |
| Blocked, with the blocking milestone named | 8 |
| Unavailable, with the reason named | 1 |
| Test suites reported | 42 |
| Spikes run against live guests | 8 |
| Duration | 124 s |

`scripts/compatibility.sh` regenerates it and exits non-zero if any claim that
*could* be checked failed — so it can gate a change.

### `AN-UNBACKED-CLAIM-IS-A-FAILURE` — CONFIRMED 2026-08-20
A claim naming a test suite that did not run is reported as **FAIL**, not
skipped. That is the drift this milestone exists to catch: a suite renamed or
deleted while its matrix row stays behind would otherwise go on asserting
something nothing checks.

Guarded two ways: a unit test that feeds the evaluator a claim naming a missing
suite and expects failure, and a second test that walks every `@Suite` declared
in `Tests/` and asserts each named suite exists.

**Untested is deliberately not failure.** A matrix that failed whenever anything
was out of reach would stop being run, and then it would record nothing at all.

### `INHERITED-IS-NOT-MEASURED` — CONFIRMED 2026-08-20
Host-independent claims render as **`inherited`** in the Intel column, never as
PASS. The first generated document showed a bold PASS there, which reads as "this
was checked on Intel" when what is true is only "this cannot vary by
architecture". No row in the matrix claims an Intel result.

### `THE-MATRIX-FOUND-TWO-DEFECTS-ON-ITS-FIRST-RUN` — 2026-08-20
Both were real, and neither had been noticed by running the same things by hand.

**1. A spike whose exit code contradicted its own verdict.**
`multiemu-multi-instance-spike` exited non-zero whenever fewer devices started
than were requested — but it is *run* with deliberate over-subscription
(`--devices 6` against a smaller budget), where refusing two of them is the
behaviour being demonstrated. It printed every check as PASS and then exited 1.
Running it by hand and reading the output had never caught this, because the
output looked right.

*Fix:* the exit code follows the checks, plus an explicit assertion that
something started at all — since total starvation, which this project has
actually seen, fails the checks anyway.

**2. A performance assertion that failed once and never again.**
`Recording performance` failed during the first matrix run and passed on every
repeat. The assertions were `p99 < 5 ms` on a 600-sample submit benchmark and
`ticksSkipped == 0` over 90 encode ticks — both tight enough that one scheduler
hiccup on a shared machine trips them.

*Fix:* the medians stay strict, because they are the property; the tails were
loosened to what the property actually needs (`p99 < 10 ms` against a 33.3 ms
budget, and `ticksSkipped <= 2` of 90). **A claim that fails at random is worse
than no claim** — it teaches people to ignore the matrix.

---

## Confirmed in Milestone 14 (file exchange and clipboard)

### `QEMU-ON-MACOS-CAN-HOST-A-9P-SHARE` — CONFIRMED 2026-08-20
`virtio-9p-pci` is present in this QEMU and `-fsdev local` works on macOS. All
three security models start: `passthrough`, `mapped-xattr` and `none`.

**`mapped-xattr` is what Multiemu emits.** It keeps ownership metadata in host
extended attributes rather than letting a guest choose host uid/gid, and it
needs no privileges — `passthrough` would.

### `THE-SHARE-REACHES-THE-GUEST` — CONFIRMED 2026-08-20 — **M14 acceptance (in part)**
Built by the production command builder, with a control run so that "the guest
sees it" means something.

| Run | virtio PCI devices the guest enabled |
| --- | --- |
| With the share | **3** |
| Without it | 2 |

The share adds a device the guest enumerates. The host directory in that run was
deliberately named with a **comma** in it (see below).

### `QEMU-OPTIONS-SPLIT-ON-COMMAS` — CONFIRMED 2026-08-20
QEMU parses `-fsdev`/`-device` values as comma-separated options and reads `,,`
as one literal comma. A user's folder may contain a comma, and without escaping
everything after it is parsed as further options — a bug, and a way to inject
settings through a directory name.

`QEMUCommandBuilder.escapeOptionValue` doubles them, and the live spike shares a
directory whose name contains a comma so the escaping under test is the escaping
that ships.

### `QEMU-CLIPBOARD-INTERFACE` — CONFIRMED 2026-08-20
Read from QEMU's own introspection at `/org/qemu/Display1/Clipboard`:

```
Register()
Unregister()
Grab(u selection, u serial, as mimes)
Release(u selection)
Request(u selection, as mimes) -> (s reply_mime, ay data)
```

Live result: **`Register` accepted, `Grab` accepted, `Request` failed.** QEMU
mediates between this process and a *guest clipboard agent*, and there is none
here — nor in a stock Android image, which is why Google's emulator moves
clipboard text over ADB instead. The host half is implemented and the guest half
is honestly unproven.

### `GUEST-PATHS-ARE-CONFINED` — CONFIRMED 2026-08-20 — **M14 acceptance**
`SharedFolder.resolve(guestPath:)` refuses every escape attempted against it.
Thirteen tests, written as attempts to get out rather than demonstrations that
it works:

| Attempt | Result |
| --- | --- |
| `../private/secret.txt`, `a/b/c/../../../../private/...`, `..` | refused |
| `/etc/passwd`, `//etc/passwd`, `/` | refused — absolute paths are never followed |
| A **symlink inside the share** pointing out of it | refused — the *result* is re-resolved, not the input trusted |
| `ok.txt\0/../../etc/passwd` | refused — a NUL truncates at the syscall, so the inspected name would not be the opened one |
| `..\..\secret`, `C:\Windows` | refused |
| A sibling directory `share-evil` next to `share` | not contained — paths compare **component-wise**, not by string prefix |
| A path that does not exist yet | still confined — confinement cannot depend on the file being there |

Read-only is the default, and a writable share says so in its `problems()`.

---

## Not verifiable at Milestone 14 — 2026-08-20

**A guest cannot mount the share here.** The fixture kernel has no 9p support of
any kind:

| Check | Result |
| --- | --- |
| Filesystems named in the kernel image | `overlay`, `tmpfs` — no `9p` |
| Modules in the initramfs (351 of them) | network drivers, `fat`, `msdos`, `fuse`, `squashfs`, `nls_*` — **no 9p, no evdev, no sound** |

So "a shared directory is readable in the guest" is **NOT YET TESTED**, for the
same reason M16 could not read a touch and M11 could not play a sound. This
initramfs is Alpine's boot-media set; it looks for a boot device and nothing
else.

**And the transport itself is an open question.** 9p is a reasonable choice and
it is what is wired, but Android kernels do not universally carry a 9p driver,
and Google's emulator shares files over ADB rather than a filesystem. Whether
Multiemu ships 9p, virtiofs or a push protocol should be decided against a real
Android guest, not guessed now. What does **not** change with that decision is
`SharedFolder`: every host path passes through it whatever carries the bytes.

---

## Confirmed in Milestone 13 (screen recording)

### `VIDEOTOOLBOX-ENCODERS-ARE-HARDWARE` — CONFIRMED 2026-08-20
Both codecs this project would consider are available and hardware-accelerated
on the development host, read from `VTCompressionSession` rather than assumed.

| Codec | Available | Hardware accelerated |
| --- | --- | --- |
| H.264 | yes | **yes** |
| HEVC | yes | **yes** |

Appending a 1080p BGRA frame through `AVAssetWriterInputPixelBufferAdaptor`
measured **median 0.28 ms, p95 0.65 ms** — 1.7% of a 60 fps budget.

### `RECORDING-DOES-NOT-TOUCH-THE-FRAME-PATH` — CONFIRMED 2026-08-20 — **M13 acceptance**
Recording reaches the interactive display in exactly one place: `submit(_:)`,
which takes a lock, stores the frame and returns. Everything else happens on the
recorder's own cadence, so the display never waits on the encoder.

| Measurement | Result | Budget |
| --- | --- | --- |
| `submit` a 1080p frame, median | **0.0000 ms** | — |
| `submit` a 1080p frame, p99 | **0.0001 ms** | 33.3 ms at 30 fps |
| Encode tick at 1080p, median | **0.90 ms** | 33.3 ms at 30 fps |
| Live handler at 30 fps, average | **3.39 ms** (slowest 4.77 ms) | 33.3 ms |
| Live handler at 60 fps, average | **3.10 ms** (slowest 16.58 ms) | 16.7 ms |

`submit` is effectively free because `GuestFrame`'s pixel array is
copy-on-write: storing it is a retain, not a copy.

### `RECORDING-PLAYS-BACK-IN-REAL-TIME` — CONFIRMED 2026-08-20 — **M13 acceptance**
A live guest was recorded, rotated **mid-recording**, then the file was read back
with AVFoundation. The file is the evidence — a recorder that reports success and
writes something no player can open has failed.

| | 30 fps | 60 fps |
| --- | --- | --- |
| Timer cadence | 181 ticks in 6.15 s = **29.4 Hz** | 240 in 4.13 s = **58.1 Hz** |
| Frames written / skipped / failed | 181 / 0 / 0 | 240 / 0 / 0 |
| Wall clock vs file duration | 6.15 s → **6.03 s** | 4.13 s → **4.00 s** |
| Track size, nominal rate | 1280×720, 30.0 fps | 1280×720, 60.0 fps |

The guest changed resolution during both runs (640×480 → 800×600) and the
frames were fitted into the fixed file size, since a video track cannot change
dimensions.

### `A-RECORDER-FED-ONLY-BY-NEW-FRAMES-RECORDS-NOTHING` — CONFIRMED 2026-08-20 — defect found and fixed
The first live run produced **3.03 s of video for 6.16 s of wall clock** — a file
that plays back at double speed.

Diagnosis took four rounds of instrumentation, and each round removed a wrong
answer rather than confirming a guess:

| Suspected | Measured | Verdict |
| --- | --- | --- |
| Encoder too slow | 0 ticks waited, 0 skipped | not it |
| Queue QoS throttled to efficiency cores | raising to `.userInitiated` changed nothing | not it |
| `DispatchSourceTimer` inaccurate | a bare timer measured **29.9–30.0 Hz** | not it |
| Silent failures inside the tick | every failure path counted: all zero | not it |
| **Ticks finding no frame** | **90 of 181** | **this** |

The recorder is fed by *new* scanouts, and a guest that is not redrawing sends
none — so recording a still screen produced nothing until the guest happened to
change. Which is precisely when someone records a still screen: to show what is
on it.

*Fix:* `RecordingSession.start(initialFrame:)` seeds the recorder with the
picture already on display. After it: 181 ticks, 181 frames, none starved.

*The lasting lesson:* every early return in the tick now increments a named
counter. A silently dropped tick is indistinguishable from a slow timer, and that
is what made the first three hypotheses look plausible.

---

## Confirmed in Milestone 12 (display controls)

### `GUEST-MODE-IS-BOUNDED-BY-THE-BOOT-FRAMEBUFFER` — CONFIRMED 2026-08-20 — **M12 acceptance**
A guest cannot select a display mode larger than the EDID built from the
virtio-GPU's boot `xres`/`yres`. The limit is **per axis** and **fixed at boot**
— it is not raised when a later resize is requested.

*Method:* the same ten mode changes were applied to a live guest at three
different boot allocations, and the guest's own scanouts were measured. The
guest is the witness; a request that QEMU accepted but the guest ignored counts
as a failure.

| Boot allocation | Modes honoured | What failed |
| --- | --- | --- |
| 1280×720 | **1 of 10** | everything larger fell back to 800×600 |
| 2560×1440 | **6 of 10** | every failure had a height above 1440; they fell back to 1920×1440 |
| **2560×2560** | **10 of 10** | nothing |

*The rule this establishes:* allocate a **square** at the largest supported
dimension. Square because rotation swaps the axes — a 2560×1440 allocation
cannot display 1440×2560, which is exactly what the middle row shows. At four
bytes a pixel this costs about **26 MB**, well inside virtio-GPU's 256 MB
`max_hostmem` default, so the memory is not the constraint the EDID is.

Encoded as `DisplayProfile.runtimeFramebufferSide`, with a test asserting it
covers every preset in either orientation.

*Also observed:* the guest's **first** scanout is 640×480 regardless of
`xres`/`yres` — the boot allocation sets the ceiling, not the starting mode.
The configured mode is applied over D-Bus once the display attaches.

### `RUNTIME-RESIZE-AND-ROTATION-WORK` — CONFIRMED 2026-08-20 — **M12 acceptance**
With the shipped allocation, all four landscape presets, all four portrait
presets, and a runtime rotation were applied to a **running** guest and honoured,
with no restart. 21 scanouts observed across the run.

Reproduce with `multiemu-display-control-spike`; `--start WxH` demonstrates the
rule by breaking it.

---

## Deferred at Milestone 11 (audio) — 2026-08-20

Audio is **not** implemented, and the reason is the same class of fixture
limitation that blocked guest-side verification in Milestone 16.

| Check | Result |
| --- | --- |
| QEMU audio backends available | `none`, `coreaudio`, `dbus`, `wav` |
| Sound devices available | AC97, `intel-hda`/`ich9-intel-hda` + `hda-*` codecs; **no virtio-sound** |
| `hda-duplex` (needs an input) | **fails to start** — `audio: Can not open 'adc' (no host audio driver)` |
| `hda-output` + `coreaudio` | QEMU runs |
| Guest kernel messages about audio | **zero**, with `coreaudio` or `none` alike |
| `dbus` audiodev | requires `-display dbus`, which this project already uses |

So the guest never enumerates a sound device at all: the fixture's kernel has no
HDA driver, and even if it did there is no `/dev/snd` — the initramfs runs no
udev, exactly as with evdev — and ALSA cannot be driven from busybox anyway.

The microphone half is separately blocked: **CoreAudio input is unavailable in
this environment**, which is why `hda-duplex` refuses to start.

M11's criterion is "guest audio reaches CoreAudio without stutter", and neither
half of that can be measured here. Implementing it now would mean shipping an
untested audio path and calling it done. It is deferred until an Android guest
exists (Milestone 4), which is also when `dbus` audiodev — capturing guest PCM
into this process over the channel already used for frames — becomes worth
building.

---

## Confirmed in Milestone 16 (input profiles)

### `GAMECONTROLLER-ELEMENTS` — CONFIRMED 2026-08-20
`GameController.framework`'s surface was read off the running system with the
Objective-C runtime rather than recalled.

| Class | Result |
| --- | --- |
| `GCExtendedGamepad` | 30 properties; **all 12** elements this design needs are present |
| `GCControllerButtonInput` | exposes `pressed`, `value`, `touched` |
| `GCControllerDirectionPad` | exposes `up`/`down`/`left`/`right` and `xAxis`/`yAxis` |
| `GCVirtualController` | **NOT PRESENT on macOS** |

Notification names are `GCControllerDidConnectNotification` and
`GCControllerDidDisconnectNotification` — not the shorter spellings a first
attempt used, which failed to compile.

*Consequence:* `GCVirtualController` being absent means a controller **cannot be
synthesised in software on macOS**. Live gamepad behaviour therefore cannot be
tested on this machine at all, which is why the translation is a pure function
over `GamepadSnapshot` and the framework bridge is kept to one thin adapter.

*Also confirmed:* `GCController.controllers()` returned an empty array with no
permission prompt, so no usage-description key was needed to enumerate.

### `GAMECONTROLLER-Y-AXIS-IS-INVERTED` — CONFIRMED 2026-08-20
`GameController` reports thumbstick `yAxis` positive **upwards**; screen space is
positive downwards. `GamepadMonitor` negates it on the way in. Left unhandled,
every vertical movement is inverted — which looks like a working mapping until
someone tries to walk forward.

### `QEMU-NEEDS-AN-EXPLICIT-MULTITOUCH-DEVICE` — CONFIRMED 2026-08-20 — defect found and fixed
Mapped input arrives as touches, and the backend attached only
`virtio-keyboard-pci` and `virtio-tablet-pci`. `org.qemu.Display1.MultiTouch`
had nothing to deliver to.

*Evidence, from the guest's own kernel log:*

| Devices configured | What Linux enumerated |
| --- | --- |
| keyboard, tablet, **multitouch** | `QEMU Virtio Keyboard`, `QEMU Virtio Tablet`, **`QEMU Virtio MultiTouch`** |
| keyboard, tablet | `QEMU Virtio Keyboard`, `QEMU Virtio Tablet` |

`virtio-multitouch-pci` is now emitted with the other input devices.

### `MULTITOUCH-ACCEPTANCE-IS-NOT-EVIDENCE-OF-DELIVERY` — CONFIRMED 2026-08-20
QEMU **accepts** `MultiTouch.SendEvent` whether or not a multitouch device
exists, and reports `MaxSlots = 10` either way.

*Method:* the same mapped events were sent to a guest with the device and to one
without. Both were accepted; neither call errored.

*Consequence:* "QEMU accepted our touches" is **not** claimed as evidence that
they were delivered, and `multiemu-input-mapping-spike` says so in its own
output. The device half is instead established by the guest kernel's
enumeration, which does discriminate (above).

This is why the control was written first. Without it, an accepted call would
have looked like a passing test.

### `LINUX-FIXTURE-HAS-NO-EVDEV` — CONFIRMED 2026-08-20 — **blocks part of M16**
The Milestone 2 Linux fixture cannot observe input at all.

| Check | Result |
| --- | --- |
| `/dev/input` | does not exist — the initramfs runs no udev |
| `/sys/class/input` | `input0`, `input1`, `input2` only |
| `/sys/class/input/inputN/` | contains **no** `eventN` directory |
| `modprobe evdev` | no such module in the initramfs |

The kernel registers the input devices, but no evdev interface is exported, so
nothing inside the guest can read a touch. Creating the node by hand from sysfs
was attempted and cannot work: there is no character device to make a node for.

*Consequence:* **the coordinates a guest ultimately reads are NOT YET TESTED.**
The mapping's own arithmetic is covered by unit tests and by the spike's offline
check — a press of the mapped key yields exactly
`touchBegin(slot: 0, x: 960, y: 180)` for a position of (0.75, 0.25) on a
1280×720 guest — but the last hop waits for an Android guest (Milestone 4).

### `M16-REVIEW-OUTCOME` — 2026-08-20
The input layer was reviewed adversarially along two lenses (mapping logic,
integration). Nine defects confirmed and fixed, each now regression-guarded:

| Defect | Consequence if shipped |
| --- | --- |
| `releaseAll()` derived key releases from keyboard state only | a key held via a **gamepad** button was never released — the guest auto-repeated it forever |
| Its release loop guarded with `contains` but read with `first` | with two bindings on one trigger it released the wrong one, stranding a key down |
| `releaseAll()` reset the remembered gamepad state | a still-held button re-fired as a fresh press — into an **unfocused** window |
| Opposing stick directions lifted the finger | holding left+right ended the touch instead of holding at centre, so releasing one re-pressed |
| Stick targets were never clamped | a stick near an edge sent touches off-screen, silently ignored |
| `InputRouter.setGuestSize` was dead code | the mapping was pinned to the *configured* resolution while the pointer used the *real* one — the two input paths disagreed about the guest's size |
| A Task per batch | a batch blocking on a D-Bus reply could be overtaken, delivering a `touchUpdate` **after** the `touchEnd` that followed it |
| `attachDisplay` resumed after a concurrent `detachDisplay` | it rebuilt a router and restarted the gamepad monitor for a guest already gone |
| `handles()` re-asked at key release | a profile changed mid-press routed press and release differently, stranding a key |

Also tightened: `GamepadMonitor` now takes its handler back off the controller
it adopted, and gamepad ownership follows the **selection** — with several
devices running they would otherwise take the one shared
`valueChangedHandler` from each other, and input would land wherever attached
last. `problems()` now rejects bindings that disagree about one stick's
geometry, and two analog controls on one stick. That last check immediately
caught an inconsistency in this project's own test fixture.

**Found independently before the review:** `InputProfile.starter` was both the
synthesised default *and* the template for a new profile. As the default it
needed a stable identity — a fresh `UUID()` per call meant the active-profile id
matched nothing, so selecting a mapping and showing which one was active would
both silently do nothing. As a template it needed a fresh one, or adding a
profile replaced the previous instead of appending. Split into `starter` (fixed
id) and `newProfile(named:)`.

**Not fixed, recorded instead:** a delivery failure mid-batch is logged and the
batch continues, but the mapper's slot bookkeeping is not rolled back, so a slot
can stay marked used after a send that never landed. Rolling it back needs a
failure path back into the mapper; the current behaviour loses at most one touch
slot per failed send and never mis-delivers.

### `ANDROID-KEY-SEMANTICS` — OPEN
Which Android action a given Linux key code reaches — whether `KEY_ESC` is Back,
for instance — has not been observed, because no Android guest has run. No
mapping is claimed anywhere in the code; `InputAction.key` passes a key through
and says nothing about what it means. To be closed in Milestone 4.

---

## Confirmed in Milestone 18 (multi-instance)

### `ASYNCSTREAM-CANCEL-FINISHES-THE-STREAM` — CONFIRMED 2026-08-20
Cancelling the Task that iterates an `AsyncStream` **terminates the stream
permanently**. A later observer attached to the same stream receives nothing and
its loop exits immediately.

*Method:* consumer 1 iterates the stream and is cancelled after receiving `1`;
consumer 2 is then attached to the **same** stream and `2` and `3` are yielded.

| | Result |
| --- | --- |
| Values received across both consumers | `[1]` |
| Consumer 2 | loop exited immediately, received nothing |

*Consequence:* `DeviceModel.restart()` must **not** re-register its session
observer. Doing so cancels the existing one, which finishes
`EmulatorSession.events`, and the replacement observes a dead stream — the
device's state would freeze at whatever it last reported, for the rest of the
app's life, while its guest ran on. The observer survives a restart on its own
because `detachDisplay()` no longer cancels session tasks.

*General rule for this codebase:* re-observe only a **new** stream. Cancelling a
consumer is equivalent to closing the stream.

### `DESCRIPTOR-OWNERSHIP-BELONGS-TO-THE-READER` — CONFIRMED 2026-08-20 — defect found and fixed
`DBusConnection.close()` guarded on `isOpen`, and `handleClosed()` clears
`isOpen` when the peer hangs up — which is the ordinary case, since QEMU exits
first. The guard therefore skipped the descriptor release on **exactly the path
that always happens**: the leak the fix was written for survived it.

Closing from `close()` is also unsafe in the other direction: the reader is a
raw `Thread` parked in `recvmsg`, and a descriptor number is reused
immediately, so closing underneath it misdirects an unrelated connection's I/O
rather than merely leaking.

*Fix:* the reader thread owns the descriptor and closes it as it exits, after
its last read. `close()` only calls `shutdown()` to unblock it, and closes
directly only when no reader was ever started (a handshake that failed early).
One owner, one close, no race.

*Found by:* three independent review lenses reported it separately, which is why
the review used distinct lenses rather than repeated passes.

### `M18-REVIEW-OUTCOME` — 2026-08-20
The M18 change set was reviewed adversarially along three lenses (concurrency,
resource accounting, lifecycle). Confirmed and fixed:

| Defect | Fix |
| --- | --- |
| `restart()` re-observed a stream its own cancel had finished | stopped re-observing; the split task groups already keep the observer alive |
| `close()` skipped the descriptor release on the common ordering | reader thread owns the descriptor |
| A guest stopping on its own never detached its display | terminal state detaches |
| `deleteDevice` raced the state mirror, so the reconcile resurrected the deleted device forever | deleted ids are exempt from retention |
| `EmulatorSession.start()` guarded on state, then suspended | claims `.starting` before the first `await` |
| `update()` rewrote every profile on every reconcile | writes only on a real change |
| `attachDisplay` leaked the connection on two failure paths | closes it |
| `supervise()` stacked supervisors across starts | cancels the previous |
| The swap warning omitted committed memory, going silent after device one | compared as a total |

**Corrected rather than shipped:** the storage accounting rested on a false
premise. `qemu-img` does not preallocate a qcow2 on any filesystem — a 64 GiB
device occupies **196 KiB** (measured) — and a device's disk is created with the
device, so its space is already gone from free space before anything starts.
Counting configured sizes as committed would have refused admissions on space
nobody took. The term was removed; sharing free space is now a warning, not a
refusal.

**Refuted by experiment:** the audit's FD_CLOEXEC blocker
(`FOUNDATION-PROCESS-DOES-NOT-LEAK-DESCRIPTORS`).

**Open, not fixed — all on the Android image path, which no production start
path reaches until M4:**
- `ensureOverlay` adopts any pre-existing file at the overlay path without
  checking it is an overlay of the requested base.
- `ensureCompositeDisk`'s existence check races the builder's own file
  creation, so a second device could overlay a half-written base.
- The composite base is keyed only on image identifier, but its contents depend
  on the per-device `userdataSizeBytes` and `slotSuffix`.
- Two devices starting on one image race to build the same derived files
  (kernel, dtb, concatenated ramdisk).

These need a per-image build lock and a backing-file identity check. They are
recorded here rather than fixed blind, because none of them can be exercised
until an Android image exists.

### `ADMISSION-MUST-CHECK-AND-CLAIM-ATOMICALLY` — CONFIRMED 2026-08-20 — **M18 acceptance**
Admitting a device is **one** step, not two. Both orderings of check and claim
are wrong, and each was built and then observed failing.

| Design | What happened |
| --- | --- |
| Check, then claim | Two devices each read a committed total that excluded the other. Both admitted; the host is over-committed. |
| Claim, then check | Every device weighed itself against its siblings' claims. Six devices starting together **all refused each other** — 0 admitted. |
| Check **and** claim together | 6 started at once → **exactly 4 admitted** (8.00 GiB of a 9.60 GiB budget), 2 refused. |

*Evidence:* `multiemu-multi-instance-spike --devices 6 --concurrent` on a 16 GiB
M5. The middle row is a real observed run, not a prediction — the claim-first
design was implemented, and the concurrent test is what exposed it.

*Why it works:* the critical section is main-actor code with no suspension point
between reading the committed total and moving the device to `.starting`
(`DeviceModel.start`). Nothing else runs in between. The spike proves the same
property with an actor method that has no `await` inside it.

*And the device must be excluded from its own total.* Once the claim is taken,
the starting device is itself "running"; counted against itself, a device large
enough to fit the host alone refuses itself. Regression-guarded by
`selfExclusionIsRequired`.

### `MULTI-INSTANCE-RUNS-ON-THE-PRODUCTION-PATH` — CONFIRMED 2026-08-20 — **M18 acceptance**
Devices started through `VirtualDeviceStore → EmulatorSession → QEMUBackend`,
not through hand-written QEMU arguments.

| Check | Result (4 devices) |
| --- | --- |
| Separate helper processes | **PASS** — 4 distinct PIDs for 4 devices |
| Read-only image shared, not copied | **PASS** — 4 devices, **1** file (compared by inode) |
| Distinct loopback-only ports | **PASS** — 4 distinct; no wildcard binding under `lsof` |
| Admission accounts for running devices | **PASS** — see below |
| Port clash refused against running devices | **PASS** |
| Admitted devices fit the host budget | **PASS** |

The admission check is only meaningful because the same request is admitted on
an empty host and refused alongside the running devices; a request refused in
both cases would prove nothing:

```
6.60 GiB of guest memory requested, but 4.00 GiB is already committed to
2 running devices and this Mac allows 9.60 GiB in total.
```

End to end, a fifth 2 GiB device on a 9.60 GiB budget is refused by
`EmulatorSession.start()` itself, not merely by the validator in isolation.

### `FOUNDATION-PROCESS-DOES-NOT-LEAK-DESCRIPTORS` — CONFIRMED 2026-08-20
`Foundation.Process` on Darwin closes descriptors it was not explicitly given.
Manual `FD_CLOEXEC` is **not** required for the sockets this project opens.

*Method:* two UNIX sockets in the parent — one with `FD_CLOEXEC` explicitly
**cleared**, one with it set — then a child that `fstat`s those exact descriptor
numbers and reports whether each is a socket.

| Descriptor | Parent state | Seen by child |
| --- | --- | --- |
| 3 | `FD_CLOEXEC` cleared | **closed** |
| 4 | `FD_CLOEXEC` set | closed |

The cleared one is the control: had descriptors been inherited at all, it would
have survived. An earlier version of this test counted entries in `/dev/fd` and
appeared to show a leak — it could not tell the socket from the directory handle
`ls` opened itself. Identify descriptors by type, never by counting.

*Caveat:* this is behaviour of Foundation's spawn, not a guarantee of the C API.
Moving to `posix_spawn` or `fork`/`exec` directly would make `FD_CLOEXEC`
mandatory.

### `QEMU-SHARES-READ-ONLY-IMAGES` — CONFIRMED 2026-08-20 — **M18 acceptance**
Two QEMU processes can hold the **same** image concurrently when both open it
`readonly=on`. No extra locking option is needed.

*Method:* four cases run against one raw image, each pair of processes paused
(`-S`) so only the image open is under test. **Case B is the control** — without
it, "both started" could simply mean locking was inactive.

| Case | First | Second | Result |
| --- | --- | --- | --- |
| A | `readonly=on` | `readonly=on` | **both running** |
| B *(control)* | writable | writable | second refused — `Failed to get "write" lock` |
| C | writable | `readonly=on` | second refused — `Failed to get shared "write" lock` |
| D | `readonly=on` | writable | second refused — `Failed to get "write" lock` |

*The rule this establishes:* an image to be shared must be opened read-only by
**every** instance, always. A single writable opener locks out every other
instance (cases C and D). Read-only is therefore a property of the **image**,
not a per-device choice.

*Note:* a read-only opener still requests a **shared write lock** — that is how
it detects writers — which is why case C fails with a different message than B.

### `SHARED-BASE-PLUS-PRIVATE-USERDATA-WORKS` — CONFIRMED 2026-08-20 — **M18 acceptance**
The intended topology runs: one shared read-only system image plus a **writable
qcow2 per device**, two devices at once, both alive.

`qemu-img info` against a userdata disk held by a running instance fails with
`Failed to get shared "write" lock` and needs `--force-share` (already adopted
in M15). The shared read-only base can be queried **without** `--force-share`.

### `HVF-ALLOCATES-GUEST-MEMORY-LAZILY` — CONFIRMED 2026-08-20
Two guests configured with **2048 MiB each** both booted to userspace and
together occupied **642 MiB** of host resident memory — not 4096 MiB.

| Elapsed | Guest A RSS | Guest B RSS | Sum |
| --- | --- | --- | --- |
| 3 s | 330 M | 331 M | 661 M |
| 13 s | 320 M | 322 M | 642 M |
| 25 s | 277 M | 275 M | 552 M |

*Consequence for admission control:* RSS must **not** be used to decide
admission — it understates what a guest may later touch. Counting the
configured `-m` at face value stays the correct policy because a guest can grow
into all of it; this measurement explains why that policy feels conservative in
practice, and it is the reason overcommitment appears to work until it does not.

### `CONCURRENT-BOOT-CONTENTION-IS-MILD` — CONFIRMED 2026-08-20
Simultaneous boots on the Apple M5 (10 logical cores), 2 vCPU and 2048 MiB each,
timed by the guest's own `Freeing unused kernel memory` timestamp.

| Guests | Total vCPUs | Slowest guest | Median | Wall to all up |
| --- | --- | --- | --- | --- |
| 1 | 2 | 0.166 s | 0.166 s | 0.61 s |
| 2 | 4 | 0.220 s | 0.214 s | 0.61 s |
| 4 | 8 | 0.251 s | 0.241 s | 0.82 s |

Four guests cost **1.51×** the solo boot time while oversubscribing nothing.
CPU is not the binding constraint on multi-instance; **memory is**.

---

## Confirmed in Milestone 17 (application shell)

### `SWIFTUI-IMAGERENDERER-CANNOT-RENDER-THIS-UI` — CONFIRMED 2026-08-20
`ImageRenderer` cannot be used to verify this interface. Rendering `MainView`
produced a red "prohibited" glyph on yellow rather than the window, and views
built from `Form`, `List` and `Picker` rendered as blank white.

*Cause:* those controls are AppKit-backed. `ImageRenderer` renders the SwiftUI
display list only, so an AppKit-hosted subtree has nothing to draw.

*Consequence:* `InterfacePreviewRenderer.swift` was deleted. Interface evidence
now comes from a real launched window.

### `CACHEDISPLAY-DOES-NOT-COMPOSITE-GLASS` — CONFIRMED 2026-08-20
`NSView.cacheDisplay(in:to:)` captures the application's own window without any
Screen Recording permission, but it does **not** composite material backdrops,
and `NSToolbar` is not part of `contentView`.

*Evidence:* in every capture the sidebar renders as a flat white rectangle and
the toolbar strip renders empty, while the same run's view hierarchy shows the
sidebar fully built (below). On macOS 26 the sidebar sits inside an
`NSContainerConcentricGlassEffectView`, which the window server composites.

*Consequence:* screenshots are used for **content and colour**; the view
hierarchy dump is used for **structure**. Neither is trusted alone.

### `SWIFTUI-AX-TREE-IS-NOT-MATERIALISED-IN-PROCESS` — CONFIRMED 2026-08-20
Walking `NSAccessibility` from inside the process returns chrome only —
`AXWindow`, `AXToolbar` and the three window buttons — and `contentView`
reports a single childless `AXGroup`. SwiftUI materialises its accessibility
tree when an assistive client attaches, which an in-process walk is not.

*Consequence:* `--dump-accessibility` emits the **view hierarchy** as its
primary evidence and keeps the accessibility walk only as a supplement.

### `INTERFACE-STRUCTURE-IS-BUILT-AS-DESIGNED` — CONFIRMED 2026-08-20 — **M17 acceptance**
The shell was launched against a scratch device store holding two devices and
its view hierarchy dumped.

| Element | Evidence from the run |
| --- | --- |
| Sidebar column | `_NSSplitViewItemViewWrapper` **268×760** (ideal 260) |
| Device list | `SwiftUIOutlineListView` **260×648** |
| Device rows | 1 × `ListTableHeaderView` + **2 × `ListTableCellView`** — one per device |
| Detail split | nested `NSSplitView`, **1180×396** display over **1180×364** log |
| Activity filter | `SwiftUISegmentedControl` **390×24** |
| Window title | `Pixel-style 1080p – Stopped` — model state reached the title bar |

With an empty store the same dump shows the section header and **no** device
rows, and the title falls back to `Multiemu`.

### `GUEST-SURFACE-NEEDS-A-PINNED-COLOUR-SCHEME` — CONFIRMED 2026-08-20 — defect found and fixed
The guest display area paints a hard black background and then drew its
placeholder text and brand mark with semantic styles. In **light** appearance
`.secondary` resolves to dark grey, so on black the placeholder was invisible.

*Found by:* capturing the same state in both appearances. Dark appearance alone
would never have shown it.

*Fix:* `.environment(\.colorScheme, .dark)` on the guest surface, so anything
drawn on it resolves against the background it actually has. Re-captured in
light appearance: brand mark and "This device is not running" both legible,
surrounding chrome still light.

### `SHEETS-RENDER-WITH-CORRECT-DEFAULTS` — CONFIRMED 2026-08-20 — **M17 acceptance**
Captured from a live window (sheet preferred over its parent, since which is key
during presentation is a race).

*New Virtual Device:* name `Android Device`; system image `No images installed`;
memory **4.00 GiB** with "This Mac allows up to 9.60 GiB for one device."
(16 GiB × the 0.60 cap in `ResourceValidator`); storage **32 GiB**; processors
**4** with "Recommended for this Mac: 4."; resolution **1920 × 1080**, density
**240 dpi**; **Create disabled** with no image installed.

*Device Settings:* real values for the selected device, and the storage row
carries "Storage cannot be resized after a device is created".

### `SETUP-PROBLEMS-NAME-THE-PATHS-SEARCHED` — CONFIRMED 2026-08-20
With `MULTIEMU_HELPER_DIR` pointed at an empty directory the shell shows
"Multiemu cannot run a virtual device yet" and reports the **exact** paths it
looked in for `qemu-img` and `qemu-system-aarch64`, alongside a host summary
(Apple M5 · Apple Silicon (arm64), 16.00 GiB, hardware virtualisation
available). A missing helper is a diagnosis, not a dead end.

### `APP-BUNDLE-SIGNS-AND-VALIDATES` — CONFIRMED 2026-08-20 — **M17 acceptance**
`scripts/build-app.sh` assembles and signs `build/Multiemu.app` (3.7 M):
`codesign --verify --deep --strict` reports valid on disk and satisfying its
designated requirement; `plutil -lint` passes on `Info.plist`.

Identifier `com.multiemu.Multiemu`, thin arm64, ad-hoc signature. The only
entitlement is `com.apple.security.files.user-selected.read-write`.

**Hardened runtime is NOT yet verified.** The script applies `--options runtime
--timestamp` only for a real identity, and no Developer ID is available on this
machine, so the signature carries no runtime flag. Carried to M21.

---

## Confirmed in Milestone 15 (snapshots and lifecycle)

### `SNAPSHOTS-CAPTURE-MACHINE-STATE` — CONFIRMED 2026-08-19 — **M15 acceptance**
Snapshots capture and restore **RAM as well as disk**, verified by state
comparison rather than by the command returning success.

*Method:* a shell variable was set (RAM only) and a marker written to the disk;
a snapshot was taken; both were then changed; the snapshot was restored; both
were read back. Recovering the shell variable is the decisive part — it exists
only in guest memory, so a disk-only check could not have detected the
difference.

| Measurement | Result |
| --- | --- |
| RAM state after restore | pre-snapshot value recovered |
| Disk state after restore | pre-snapshot marker recovered |
| Capture | **0.357 s** |
| Restore | **0.444 s** |
| Machine state size | **183.9 MiB** for a 2 GiB guest |
| Listing and deletion | both succeeded |

### `QMP-SNAPSHOTS-ARE-JOBS` — CONFIRMED 2026-08-19
`snapshot-save`, `snapshot-load` and `snapshot-delete` are asynchronous **jobs**,
not synchronous commands. Signatures from QEMU's own schema:

```
snapshot-save(job-id, tag, vmstate, devices)
snapshot-load(job-id, tag, vmstate, devices)
snapshot-delete(job-id, tag, devices)
```

The command returns success as soon as the job is *created*, so the outcome must
be read from `query-jobs`; a job that concluded with an `error` field is a
failure the original reply never mentions. Concluded jobs also persist until
`job-dismiss`, so dismissal is mandatory rather than tidy-up — otherwise the next
job of the same name collides with the last one's corpse.

### `DRIVE-ID-AND-NODE-NAME-SHARE-A-NAMESPACE` — CONFIRMED 2026-08-19 — **defect found and fixed**
Snapshots address block nodes by name, so drives need explicit, stable
`node-name` values — QEMU's generated `#block001` names change between runs.
But giving a drive the same string for `id` and `node-name` fails outright:

```
Device name 'disk0' conflicts with an existing node name
```

The two live in **one namespace**. Node names now default to `<id>-node`.

*Found by:* running against QEMU. The failure surfaced through the Milestone 3
machinery exactly as designed — `failed` state, QEMU's stderr captured, and the
reason printed — which is what made it a two-minute diagnosis.

### `QEMU-IMG-NEEDS-FORCE-SHARE-ON-A-RUNNING-DISK` — CONFIRMED 2026-08-19 — **defect found and fixed**
`qemu-img info` cannot read a disk a running guest holds a write lock on. It
fails rather than returning partial data, which surfaced as a snapshot list that
was silently **empty** and a machine state size of **0 B** — both plausible
enough to be mistaken for "snapshots didn't really work".

Read-only queries now pass `--force-share`, after which the same run reported
183.9 MiB of state and listed the snapshot correctly.

### `SNAPSHOT-TAGS-ARE-CONSTRAINED` — CONFIRMED 2026-08-19
Tags become identifiers inside a qcow2 image, so they are validated rather than
passed through: non-empty, at most 128 characters, and limited to letters,
digits, spaces and `- _ .`.

### `LIFECYCLE-COMPLETE` — CONFIRMED across M3, M9 and M15
The device lifecycle is now covered end to end, each piece verified against a
real guest:

| Operation | Verified in |
| --- | --- |
| Start, boot detection, running | M3 |
| Graceful shutdown with escalation | M3 (guest ignored ACPI; `quit` succeeded) |
| Crash detection and recovery | M3 (external `SIGKILL`, control state intact, restart) |
| Restart | M3 |
| Factory reset | M9 (data cleared, profile kept) |
| Persistence across restart | M9 (marker survived a full stop/start) |
| Snapshot capture and restore | M15 |

---

## Confirmed in Milestone 9 (persistence and profiles)

### `GUEST-DATA-PERSISTS-ACROSS-RESTART` — CONFIRMED 2026-08-19 — **M9 acceptance**
Guest writes survive a complete shutdown and a fresh boot.

*Method:* a device was created through the real `VirtualDeviceStore`. One guest
wrote a marker straight to its block device and synced; that guest was stopped
entirely; a **second** guest booted against the same qcow2 file and read the
marker back to a serial log. Both guests were driven by typing into their shells
over the Milestone 6 keyboard path, so the run is unattended.

| Stage | userdata allocated | Logical |
| --- | --- | --- |
| Freshly created | 196 KiB | 32.00 GiB |
| After the guest wrote | 384 KiB | 32.00 GiB |
| After the second guest read it back | 384 KiB | 32.00 GiB |
| After factory reset | 196 KiB | 32.00 GiB |

The marker was recovered in the second boot.

### `SPARSE-ALLOCATION-IS-REAL` — CONFIRMED 2026-08-19 — **product rule**
A 32 GiB device costs **196 KiB** until the guest writes, and grows only by what
is written. The constraint "avoid allocating the full configured virtual disk
eagerly when a safe sparse format is available" is satisfied and measured, not
assumed.

### `FACTORY-RESET-KEEPS-THE-PROFILE` — CONFIRMED 2026-08-19
Factory reset recreates the writable partitions and returns allocation to its
fresh value, while the device keeps its name, resources and display settings.
Read-only partitions are untouched, because they are shared between devices.

### `ISO8601-TRUNCATES-SUB-SECOND-TIMES` — CONFIRMED 2026-08-19 — **defect found and fixed**
Foundation's `.iso8601` date strategy encodes whole seconds only. A profile
saved and reloaded therefore came back with a `modifiedAt` **earlier** than the
value it was written from, so a modification date appeared to move backwards
across a save/load cycle.

*Fix:* configuration JSON uses an ISO-8601 formatter with
`.withFractionalSeconds`, and `create`/`save` now return the persisted profile so
the caller's copy and the file can never disagree.

*Found by:* a unit test asserting `reloaded.modifiedAt >= original.modifiedAt`.

### `ISO8601DATEFORMATTER-IS-NOT-SENDABLE` — CONFIRMED 2026-08-19
A shared `static let ISO8601DateFormatter` does not compile under Swift 6 strict
concurrency. Configuration coders build one per call; writes are rare enough
that the allocation is irrelevant next to correctness.

### `QCOW2-VIA-QEMU-IMG` — CONFIRMED 2026-08-19
Disk creation and inspection go through `qemu-img` rather than a hand-written
qcow2 writer, for the same reason QEMU is used rather than a hand-written VMM:
the format has refcount tables and cluster allocation rules that a from-scratch
implementation would get subtly wrong, and a subtly wrong disk loses user data
rather than failing loudly. `qemu-img` carries the same GPL-2.0 obligations and
the same rule — a separate executable, never linked.

---

## Confirmed in Milestone 7 (networking)

### `GUEST-NETWORKING-BOTH-DIRECTIONS` — CONFIRMED 2026-08-19
User-mode networking works in both directions, verified entirely on loopback
with no external egress.

*Method:* the guest's interface was configured by **typing into its shell** over
the D-Bus keyboard interface from Milestone 6 — the first time one milestone's
capability was used to test another's.

| Leg | Method | Result |
| --- | --- | --- |
| Guest interface up | `ip addr add 10.0.2.15/24`, reported over serial | address present |
| Guest to host | guest fetched a marker from a loopback server via libslirp's gateway `10.0.2.2` | marker received; probe served 1 request |
| Host to guest | host connected to the forwarded port and read a marker served inside the guest | marker received |
| Binding | `lsof -nP -iTCP:<port> -sTCP:LISTEN` | `TCP 127.0.0.1:59281 (LISTEN)` |

Static addressing was used rather than DHCP: libslirp's addresses are fixed, and
this isolates the network path from whatever DHCP client an initramfs happens to
ship.

### `PORT-FORWARDS-ARE-LOOPBACK-ONLY` — CONFIRMED 2026-08-19 — **security property**
The forwarded port binds `127.0.0.1` and nothing else, confirmed by `lsof`
rather than by reading our own command line back. This matters most for
Milestone 8: an ADB port on a wildcard address would expose the guest — and a
root shell on it — to everything on the local network.

### `DNS-AND-INTERNET-NOT-TESTED` — OPEN — **deliberate**
libslirp forwards DNS at `10.0.2.3` to the host's resolver, so exercising it
would reach the internet. That is external egress and was not performed.

To close it, with network approval, run from the guest shell: bring up `eth0`
with `udhcpc`, resolve a public hostname against `10.0.2.3`, and fetch a public
URL with `wget`. The path is the same one already proven to the gateway; only
the destination differs.

### `BRIDGED-NETWORKING-REFUSED-EXPLICITLY` — CONFIRMED 2026-08-19
`GuestNetworkConfiguration` refuses `bridged` mode with its reason rather than
silently falling back to user mode. Milestone 2 established that QEMU's
`vmnet-*` backends fail unprivileged; downgrading quietly would hide a real
difference in reachability from the user.

---

## Confirmed in Milestone 6 (input)

### `QEMU-DBUS-INPUT-INTERFACES` — CONFIRMED 2026-08-19 — **ground truth, not documentation**
QEMU's own introspection XML gives the exact contract, so none of it is guessed:

```
org.qemu.Display1.Keyboard    Press(u) Release(u)            .Modifiers: u
org.qemu.Display1.Mouse       Press(u) Release(u)
                              SetAbsPosition(uu) RelMotion(ii)  .IsAbsolute: b
org.qemu.Display1.MultiTouch  SendEvent(utdd)                 .MaxSlots: i
org.qemu.Display1.Console     RegisterListener(h)
                              SetUIInfo(qqiiuu)
                              .Label .Head .Type .Width .Height .DeviceAddress .Interfaces
```

Introspecting first removed the largest remaining risk in a hand-written D-Bus
client. `multiemu-display-spike --introspect` reproduces it.

### `KEYBOARD-INPUT-REACHES-THE-GUEST` — CONFIRMED 2026-08-19 — **verified textually**
Keystrokes reach the guest and the key codes are correct.

*Method:* the guest boots with `console=ttyAMA0 console=tty0`, so `/dev/console`
is the framebuffer (where keyboard input lands) while `ttyAMA0` remains a serial
device captured to a file. Multiemu then types
`echo MULTIEMU_INPUT_OK_145045 > /dev/ttyAMA0` through
`org.qemu.Display1.Keyboard`.

*Result:* the marker appeared in the serial log, and the command is visible on
the captured framebuffer. Every character survived, including `_` (shift+minus),
`>` (shift+dot) and `/`. The guest also reported the devices:

```
input: QEMU Virtio Keyboard as .../input/input0
input: QEMU Virtio Tablet as .../input/input1
MULTIEMU_INPUT_OK_145045
```

This is a text-based proof rather than a visual one, so it can run unattended.

### `POINTER-MODE-MUST-BE-NEGOTIATED` — CONFIRMED 2026-08-19 — **defect found and fixed**
Sending `RelMotion` to an absolute pointing device is refused outright:

```
org.qemu.Display1.Error.Invalid: Mouse is not relative
```

A `virtio-tablet-pci` is absolute; a plain mouse is relative. QEMU does not
adapt, so the client must read `Mouse.IsAbsolute` and choose `SetAbsPosition` or
`RelMotion` accordingly. `QEMUInputClient.move(to:)` now does that and caches the
answer, synthesising deltas from the last position for relative devices.

Found by running against a real guest, not by review.

### `POINTER-BUTTON-ENCODING` — CONFIRMED 2026-08-19
`Mouse.Press(button: u)` takes QEMU's own `InputButton` ordinals
(left 0, middle 1, right 2, wheel-up 3, wheel-down 4), **not** Linux `BTN_*`
constants. `BTN_LEFT` is `0x110` and would be an out-of-range button.

### `QEMU-DBUS-KEYCODE-ENCODING` — CONFIRMED (main block) 2026-08-19
`Keyboard.Press(keycode: u)` accepts Linux evdev codes. Confirmed empirically for
letters, digits, punctuation, Shift, Enter and Space by typing a shell command
the guest then executed.

*Note:* for the main keyboard block, Linux evdev codes and AT set-1 scancodes
coincide — Linux derived its codes from that set — so this test cannot
distinguish them. The **extended block** (arrows, Home/End/PageUp/PageDown,
Insert/Delete) is where the two diverge and remains unconfirmed; those are the
first place to look if a navigation key misbehaves.

### `CONSOLE-GEOMETRY-WITHOUT-A-SCANOUT` — CONFIRMED 2026-08-19
`org.qemu.Display1.Console` exposes `Width` and `Height` as properties, so the
guest's resolution can be read immediately instead of waiting for the first
frame. Reported 1280×800 on a guest configured for exactly that.
`MultiTouch.MaxSlots` reported **10**.

---

## Confirmed in Milestone 5 (Metal presentation)

### `METAL-PRESENTATION` — CONFIRMED 2026-08-19 — **guest pixels on screen**
Guest frames are presented in a real macOS window through Metal.

*Evidence:* `multiemu-display-window` with an Alpine guest, 16 s run:

| Measurement | Result |
| --- | --- |
| Frames presented | 82 |
| Guest resolution | 1920×1080 |
| Window | 900×620 **points** |
| Drawable | 1800×1240 **pixels** |
| Backing scale | 2.0× |
| Capture | PNG at 1920×1080, visually correct |

### `HIDPI-DRAWABLE-SIZING` — CONFIRMED 2026-08-19
The drawable is sized in **pixels**, not points: a 900×620-point view on a 2.0×
display produced an 1800×1240-pixel drawable. Sizing it in points renders at
half resolution — a bug that is easy to miss because the image is otherwise
entirely correct, just soft.

### `GUEST-RESOLUTION-INDEPENDENCE` — CONFIRMED 2026-08-19 — **product requirement**
A 1920×1080 guest displayed correctly in a 900×620-point window, and the
screenshot was captured at **1920×1080**, not at window size. Resizing the
window changes only how the image is fitted, never what the guest believes its
resolution to be. Nine scaling-geometry tests pin the rule across surface sizes
from 640×480 to 3840×2160.

### `HOST-FRAME-PATH-COST` — CONFIRMED 2026-08-19 — **9% of a 60 fps budget**
Everything Multiemu does between bytes arriving and pixels being drawn, at
1920×1080:

| Stage | Median |
| --- | --- |
| D-Bus `Scanout` decode (3.9 MiB) | 0.21 ms |
| Texture upload | 0.39 ms |
| Upload + render combined | 1.31 ms → 764 fps ceiling |
| 1080p → 4K render (incl. GPU wait) | 2.12 ms → 472 fps ceiling |

Total host path ≈ **1.5 ms**, against a 16.7 ms budget at 60 fps. All three are
regression-guarded by tests that fail above the budget.

*What this does not establish:* sustained frame rate under a real workload. A
static text console cannot exercise it — that measurement needs an animating
guest, i.e. Android, and is deferred to Milestone 19 with the workload that
makes it meaningful.

### `METAL-ALPHA-AND-ORIENTATION` — CONFIRMED 2026-08-19
Two mistakes that render a *correct* framebuffer wrongly, both now pinned by
tests:

- QEMU's `x8` padding byte must not be treated as alpha. `bgra8Unorm` with
  premultiplied alpha renders a perfect framebuffer as fully transparent; the
  shader forces alpha opaque.
- NDC y points up while texture v points down. A four-quadrant test frame
  asserts the guest's top-left lands in the surface's top-left, so a vertical
  flip cannot pass unnoticed.

---

## Confirmed in Milestone 5 (frame delivery)

### `QEMU-DBUS-FRAME-DELIVERY` — CONFIRMED 2026-08-19 — **the display pipeline works**
Guest frames arrive over QEMU's D-Bus display interface on macOS, decode
correctly, and reach disk as PNG. QEMU is unpatched.

*Evidence:* `multiemu-display-spike` with an Alpine guest on virtio-gpu:

| Measurement | Result |
| --- | --- |
| `RegisterListener` | accepted |
| Scanouts received | 53 in 10 s |
| First scanout | **0.116 s** after QEMU launch |
| Frame | 1920×1080, 7.9 MiB, `x8r8g8b8 (32bpp, 0x20020888)` |
| Written | PNG, visually correct guest console |

The scanout *rate* (≈5/s) reflects how often a static text console changes, not
a throughput limit.

### `DBUS-FRAME-DECODE-COST` — CONFIRMED 2026-08-19 — **550× faster than VNC**
Decoding a 3.9 MiB `Scanout` message costs **0.21 ms median**, a 4721 fps
ceiling — roughly 80× the headroom a 60 fps budget needs, against QEMU's VNC
server at 117 ms for the same framebuffer.

*This was not true when first written.* Representing `ay` as `[DBusValue.byte]`
meant four million boxed enum values per frame. A dedicated `byteArray([UInt8])`
case fixed it; the benchmark is now a regression guard that fails under 8 ms.

### `DBUS-LISTENER-SASL-ROLE-IS-INVERTED` — CONFIRMED 2026-08-19 — **cost a debugging cycle**
On the **console** connection (from `add_client`) Multiemu is the SASL client.
On the **listener** connection created by `RegisterListener`, QEMU authenticates
as the **server**, so Multiemu must drive that handshake as the client too —
while still being the side that *implements* the Listener interface and receives
QEMU's method calls.

**SASL role and message role are independent.** Assuming they matched produced a
silent hang: QEMU replied to `RegisterListener` successfully and then never
spoke, because both ends were waiting for the other to open the handshake. Only
tracing the message flow showed the reply had already arrived.

### `DBUS-HANDSHAKE-MUST-NOT-BLOCK-AN-ACTOR` — CONFIRMED 2026-08-19 — **defect found and fixed**
The SASL handshake is blocking and line-oriented. Running it inside an actor
occupies a cooperative-pool thread for its duration; with the QMP client, two
D-Bus connections and their reader loops all live at once, the pool starved and
the whole tool deadlocked with no output.

*Fix:* the handshake runs on a dedicated thread and resumes a continuation, the
same rule the reader loops already followed.

*Also learned:* the tool produced **no output at all** while hung, because stdout
is block-buffered when redirected. `setvbuf(stdout, nil, _IONBF, 0)` in
long-running tools turns a silent hang into a visible one.

### `DBUS-RESOLUTION-CHANGES-ARE-JUST-SCANOUTS` — CONFIRMED 2026-08-19
When the guest changed mode from 640×480 to 1920×1080, the new size simply
arrived as the next `Scanout` with new dimensions. No negotiation and no
pseudo-encoding is required — a genuine advantage over RFB, where failing to
request DesktopSize silently truncates every frame (`RFB-DESKTOP-SIZE-REQUIRED`).

### `DBUS-LISTENER-SIGNATURES` — CONFIRMED 2026-08-19 (partially)
Observed on the wire against QEMU 11.1.0:

| Member | Signature | Status |
| --- | --- | --- |
| `Scanout` | `uuuuay` (width, height, stride, pixman format, data) | received and decoded |
| `MouseSet` | `iii` | received; belongs to the input milestone |
| `Update` | — | **never sent** for virtio-gpu 2D on this path; QEMU sent full `Scanout`s only |

That `Update` never appeared is worth knowing: a pipeline optimised only for
partial updates would have no fast path at all here.

---

## Confirmed in Milestone 5 (display spike)

### `QEMU-DBUS-DISPLAY-MACOS` — CONFIRMED 2026-08-19 — **the frame path exists**
QEMU's D-Bus display channel can be established on macOS, without patching QEMU
and without a session bus.

*Evidence:* `multiemu-display-spike`, using Multiemu's own QMP client and
`SCM_RIGHTS` transfer rather than a throwaway script:

| Step | Result |
| --- | --- |
| `-display dbus,p2p=on` | starts; `query-display-options` → `{"p2p":true,"type":"dbus"}` |
| `socketpair` + `getfd` with `SCM_RIGHTS` | accepted |
| `add_client protocol=@dbus-display` | **ACCEPTED** |
| D-Bus `AUTH EXTERNAL <uid-hex>` | `OK 3d0fac2a9036fd986889e2f86a858c1d` |
| `BEGIN` | message phase entered |

*Note on the earlier probe:* `add_client` validates `fdname` **before**
`protocol`, so probing protocol names without a real descriptor returns
"File descriptor named ... has not been found" for every value, valid or not.
The protocol is only actually validated once a descriptor exists.

*Closed:* frame delivery now works — see `QEMU-DBUS-FRAME-DELIVERY` above.

### `VNC-FRAME-PATH-THROUGHPUT` — CONFIRMED 2026-08-19 — **works, but not fast enough**
VNC is compiled into the macOS QEMU build and delivers real pixels, but its
server cannot meet the product's frame rate floor at 1080p.

*Evidence:* an RFB 3.8 client connected, negotiated, and captured a real guest
console frame (Alpine boot text). Then, full-frame non-incremental Raw updates
at 1920×1080 (7.91 MiB/frame), 20 runs:

| Metric | Value |
| --- | --- |
| median | 117.03 ms → **8.5 fps** ceiling |
| p95 | 934.62 ms |
| worst | 988.91 ms |
| throughput | 68 MiB/s |

*Control, to attribute the cost honestly:* the **same client code** draining
7.91 MiB from a plain loopback socket ran at **1.61 ms / 4910 MiB/s**. The
client is therefore ~70× faster than the measured path, so the bottleneck is
QEMU's VNC server, not the client.

*Verdict:* VNC is a proven fallback for correctness work — it produces real
pixels today — but it is not the product's frame path. 30 fps needs ≤ 33.3 ms
and 60 fps needs ≤ 16.7 ms; the median alone is 3.5× over the floor, and the p95
is 28× over.

### `VIRTIO-GPU-GUEST-CAPABILITIES` — CONFIRMED 2026-08-19 — **from inside the guest**
The guest's own DRM driver reports what the host build provides:

```
[drm] pci: virtio-gpu-pci detected at 0000:00:02.0
[drm] features: -virgl +edid -resource_blob -host_visible
[drm] number of scanouts: 1
Console: switching to colour frame buffer device 160x50
```

`-virgl` and `-resource_blob` confirm from the guest side what Milestone 2
inferred from absent device names: this QEMU has **no 3D and no blob resources**.
3D requires our own build with `--enable-virglrenderer`; blob resources and
host-visible memory are what modern gfxstream/Venus paths need, so their absence
bounds what is achievable before we build our own QEMU.

### `RFB-DESKTOP-SIZE-REQUIRED` — CONFIRMED 2026-08-19
A VNC client that does not request the **DesktopSize pseudo-encoding (-223)**
never learns that the guest changed resolution. The spike initially reported a
640×480 framebuffer and silently captured the top-left corner of what the guest
had already reconfigured to 1920×1080. Any RFB client Multiemu keeps must
request `-223`.

---

## Confirmed in Milestone 4

### `BOOT-IMAGE-HEADER-LAYOUT` — CONFIRMED (cross-implementation) 2026-08-19
Multiemu's parser reads Android `boot.img` (header versions 0–4) and
`vendor_boot.img` (3–4) correctly, validated against an **independently written**
Python builder rather than only against itself.

*Evidence:* a Python script constructed a v4 `boot.img` and `vendor_boot.img`
directly from the `bootimg.h` structures; `multiemu-image inspect` read both:

| Field | Written by Python | Read by Swift |
| --- | --- | --- |
| kernel | 12345 bytes | 12.1 KiB at offset 4096 |
| ramdisk | 6789 bytes | 6.6 KiB at offset 20480 |
| os_version word | Android 14.0.0, patch 2024-06 | `14.0.0`, `2024-06` |
| vendor ramdisk | 4321 bytes | 4.2 KiB at offset 4096 |
| vendor dtb | 999 bytes | 999 B at offset 12288 |
| command lines | exact strings | exact strings |

*Still open:* validation against a real Google- or AOSP-produced image. Two
independent implementations of the same documented structure agreeing is strong,
but it is not the same as reading an artifact neither of them produced. Run
`multiemu-image inspect <real boot.img>` to close this fully.

### `VENDOR-BOOT-HEADER-SPANS-TWO-PAGES` — CONFIRMED 2026-08-19 — **defect found and fixed**
The `vendor_boot` header is **2112 bytes at version 3 and 2128 at version 4**,
so with a 2048-byte page it occupies **two** pages, not one. The parser
originally assumed a single-page header and located the vendor ramdisk 2048
bytes early — producing a ramdisk that looks like data and would have failed at
boot for no visible reason.

*Fix:* every section offset is now derived from the bytes the header actually
consumed, rounded up to a page, rather than assuming one page. This is correct
for both containers at every page size.

*Caught by:* a round-trip test against a synthetic image, before any real image
existed. This is the case for building the parser before the download rather
than after.

### `SWIFTPM-STALE-ENUM-LAYOUT` — CONFIRMED 2026-08-19 — **build hazard, not a code defect**
Adding cases to a public enum in a library target (`BootMilestone.Kind` in
`MultiemuBackend`) left stale object files in dependent test targets, producing
a reproducible **SIGSEGV inside unrelated test code** — the crash report pointed
at `MockBackend.start(_:)`, which was innocent.

*Remedy:* `swift package clean` before trusting a failure that follows a change
to a cross-module enum or struct layout.

**Happened twice.** The second occurrence was a struct signature change
(`GuestStartRequest` gaining `disks` in place of two array properties), which
surfaced as an undefined-symbol link error naming the *old* initialiser. Treat
any layout change to a public type in a library target as requiring a clean.

*Also learned:* `swift build --build-tests` reported success while test targets
had compile errors. Only `swift test` is trustworthy for verifying test code.

### `RAMDISK-CONCAT-ORDER` — OPEN
*Claim:* for direct kernel boot the vendor ramdisk must precede the generic
ramdisk in the concatenated initrd, so that generic entries override vendor ones
(Linux extracts concatenated cpio archives in order, last writer winning).
*Status:* implemented in that order and covered by a test that pins it, but not
yet confirmed against a booting Android image. It is a one-line change if
reversed.

### `GPT-COMPOSITE-DISK` — CONFIRMED (two independent parsers) 2026-08-19
Multiemu can build the single GPT-partitioned disk Cuttlefish-style images
expect, and the result is valid according to two parsers that are not ours.

*Evidence, on a 7-partition 8.02 GiB disk:*

| Check | Result |
| --- | --- |
| Independent Python parser | protective MBR `0xEE`; primary header CRC `0x77aa4b90` stored == computed; entry-array CRC `0x58aca588` stored == computed; backup header CRC matches and points to LBA 1; same disk GUID in both headers; no overlaps; all partitions inside the usable LBA range |
| **macOS's own parser** (`hdiutil attach -nomount -readonly`) | `GUID_partition_scheme` with all 7 partitions at the correct sizes and type "Linux Filesystem" |
| Type GUID round trip | `0fc63daf-8483-4772-8e79-3d69d8477de4` decoded correctly by Python's `uuid.UUID(bytes_le=)`, confirming the mixed-endian on-disk encoding |
| Sparse allocation | 8.02 GiB logical, **6.0 MiB allocated** |

The disk image was detached cleanly; nothing was left attached.

### `QCOW2-FORMAT-ASSUMPTION` — CONFIRMED 2026-08-19 — **defect found and fixed**
`QEMUBackend` hardcoded `format=qcow2` for every writable image. Android
partition images and the composite disk are **raw**, so the first real Android
start would have failed inside QEMU with a format error.

*Fix:* `GuestStartRequest` now carries `[GuestDiskImage]` with an explicit
`format` and `isReadOnly` per disk. The format is never probed from file
contents — QEMU documents format probing as a security hazard, since a guest can
write qcow2-looking bytes into a raw image it controls.

*Found by:* wiring the composite disk into the boot path, not by review.

### `ANDROID-IMAGE-DOWNLOAD-URL` — OPEN
*Claim:* the Android CI artifact URL pattern
`/builds/submitted/{buildId}/{target}/latest/{artifact}` resolves for
`aosp_cf_arm64_phone-*`.
*Status:* implemented in `scripts/fetch-android-image.sh` but unverified — the
host is not reachable from this environment. The script fails loudly with the
attempted URL and instructions to copy the real link from the CI web UI.

### `ANDROID-PARTITION-LAYOUT` — OPEN — **M4 gate**
*Claim:* an Android image can be booted with one virtio-blk device per
partition, rather than requiring a single composite GPT disk with Android's
expected partition names.
*Why it matters:* Android locates partitions through `/dev/block/by-name/`
symlinks that ueventd creates from the device tree or `androidboot.boot_devices`.
Cuttlefish-style images assume a composite disk that `cvd` builds. If the image
requires that layout, Multiemu must build the composite disk itself — a
well-defined but separate piece of work, deliberately not written speculatively.
*How to close:* attach a real image both ways and read first-stage init's console.

---

## Confirmed in Milestone 3

### `QMP-CONTROL-CHANNEL` — CONFIRMED 2026-08-19
QMP over a UNIX domain socket works end to end against QEMU 11.1.0: connection
with retry while QEMU is still starting, greeting (`QEMU 11.1.0`, capabilities
`["oob"]`), `qmp_capabilities` negotiation, `query-status` → `running` on a live
guest, and asynchronous events delivered separately from command replies.

*Evidence:* `multiemu-session --mode run` printed `[qmp] query-status -> running`
while the guest was up, and received `POWERDOWN` then
`SHUTDOWN: {"guest":false,"reason":"host-qmp-quit"}`.

### `UNIX-SOCKET-PATH-LIMIT` — CONFIRMED 2026-08-19 — **a real trap, designed around**
`sockaddr_un.sun_path` is **104 bytes** on Darwin. Ordinary project paths exceed
it once a per-device subdirectory is added:

| Path | Bytes |
| --- | --- |
| Repository root | 98 |
| Naive `<repo>/devices/<uuid>/qmp.sock` | **152 — fails** |
| `QMPClient.makeSocketPath` output | 69 |

*Consequence:* control sockets never live beside the virtual device. They are
created in the system temporary directory under a short random name and removed
on teardown. `QMPClient` validates the length and throws
`socketPathTooLong(path:limit:)` naming both numbers rather than failing with a
bare `ENAMETOOLONG`. This would otherwise have surfaced in Milestone 9, when
per-device directories arrive.

### `SHUTDOWN-ESCALATION` — CONFIRMED 2026-08-19
The graceful-stop ladder behaves as designed, and the first rung genuinely does
get ignored in practice.

| Rung | Observed |
| --- | --- |
| `system_powerdown` | `POWERDOWN` event emitted; the guest (an initramfs shell with no ACPI handler) did not act on it |
| `quit` | QEMU exited; `SHUTDOWN` reported `reason: "host-qmp-quit"` |
| `SIGTERM` / `SIGKILL` | not reached |

*Consequence:* a shutdown implementation that only sends `system_powerdown` would
hang forever on exactly this kind of guest. The escalation is not defensive
padding.

### `CRASH-RECOVERY` — CONFIRMED 2026-08-19 — **M3 acceptance criterion**
An external `SIGKILL` of the backend process leaves the application fully intact.

*Evidence:* `multiemu-session --mode crash` located the QEMU pid with `pgrep`,
killed it with `SIGKILL`, and the session reported:

- state `failed`, kind `backendTerminatedUnexpectedly`, backend exit code **9**
- **40 console lines retained**, including the last lines before death
- device name, resources, run count and the full boot timeline still present
- `restart()` produced a fresh backend and reached `running` again; run count 1 → 2

### `SESSION-STATE-RACE` — CONFIRMED 2026-08-19 — **defect found and fixed**
When `EmulatorSession.start()` threw, a caller that immediately read `state` saw
a stale `.starting`, because the backend's `.failed` state reaches the session
asynchronously over its event stream. Found by a unit test, not by inspection.
Fixed by reading the backend's state directly on the error path before throwing;
safe against reordering because `.failed` is terminal.

---

## Confirmed in Milestone 2, after QEMU was installed

QEMU 11.1.0 (Homebrew) on Apple M5 / macOS 26.5.2. Accelerators reported by the
binary: `hvf`, `tcg`.

### `QEMU-HVF-AARCH64-MATURITY` — CONFIRMED 2026-08-19 — **M2 gate, passed**
`qemu-system-aarch64 -machine virt -accel hvf -cpu host` boots a modern ARM64
Linux kernel on Apple Silicon, reliably and fast.

*Evidence:* Alpine 3.21 netboot kernel (Linux 6.12.1-3-lts), 4 vCPU, 2048 MiB,
5 consecutive runs. The guest reported `PSCIv1.1 detected in firmware`,
`Machine model: linux,dummy-virt`, enumerated both virtio-pci devices, ran its
initramfs and reached a userspace shell.

| Milestone | Elapsed |
| --- | --- |
| `kernelStarted` | 0.157 s |
| `kernelMemoryFreed` | 0.297 s |
| `initStarted` | 0.305 s |
| `initramfsShell` | 5.362 s |

Total wall time 5.370–5.423 s across 5 runs (median 5.371 s). Roughly 5.0 s of
that is Alpine's fixed boot-media search timeout — a wall-clock delay, not CPU
work — because no disk was attached. The CPU-bound portion is
launch → `initStarted` = **0.305 s**.

### `QEMU-ACCELERATION-DELTA` — CONFIRMED 2026-08-19 — **first real cross-arch measurement**
Measured, rather than asserted, on one host with one workload.

| Guest | Accelerator | launch → `initStarted` | Relative | Total (median) |
| --- | --- | --- | --- | --- |
| arm64 | **hvf** | **0.305 s** | 1.0× | 5.371 s |
| arm64 | tcg | 1.575 s | 5.2× | 7.794 s |
| x86_64 | tcg | 3.196 s | 10.5× | 9.325 s |

*Caveats, which matter more than the numbers:* this is kernel boot, which is
mostly serial initialisation and is **not** representative of a sustained
Android UI workload; TCG's relative cost typically grows with hot user-space
code. Totals understate the difference because each includes the same fixed 5 s
delay. Treat 5.2× and 10.5× as a floor on the penalty, not an estimate of it.

*Consequence:* the `degraded` label on both TCG rows of the compatibility matrix
is now evidence-backed. x86_64-on-Apple-Silicon does run — and is 10× slower on
the one thing measured so far.

### `QEMU-VHOST-USER-GPU-MACOS` — CONFIRMED **FALSE** 2026-08-19 — **highest-risk item, resolved against the plan**
```
qemu-system-aarch64: -device vhost-user-gpu-pci:
    'vhost-user-gpu-pci' is not a valid device model name
```
`-device help` lists **no** vhost-user devices at all. (`vhost-user` does appear
as a *netdev* backend — a different code path, and not a graphics one.) This is
a full-featured Homebrew build with 361 devices, so the absence is platform,
not packaging.

`virtio-gpu-gl-pci` is likewise absent, so this build has no virgl 3D either;
that one *is* a build option (`--enable-virglrenderer`) and our own build could
enable it.

*Consequence:* the Milestone 5 design as written in Milestone 1 is dead. See
`QEMU-DBUS-DISPLAY-MACOS` for the replacement.

### `QEMU-DBUS-DISPLAY-MACOS` — PARTIALLY CONFIRMED 2026-08-19 — **the replacement path**
QEMU's D-Bus display backend is present on macOS and initialises in
peer-to-peer mode.

| Command | Result |
| --- | --- |
| `-display dbus` | fails: `Cannot spawn a message bus without a machine-id` |
| `-display dbus,p2p=on` | **starts cleanly** |
| `-device virtio-gpu-pci` with `-display none` | attaches cleanly |

*Still to prove (Milestone 5):* that scanouts actually arrive over the
peer-to-peer connection and can be mapped into a Metal texture. Backend
initialisation is not frame delivery.

*Fallback if it fails:* patch QEMU with a native display backend and publish the
patch as GPL source.

### `QEMU-VMNET-PRIVILEGES` — CONFIRMED 2026-08-19
```
-netdev vmnet-shared,id=n0:  cannot create vmnet interface:
    general failure (possibly not enough privileges)
-netdev vmnet-bridged,...:   same
```
*Consequence:* unprivileged user-mode networking (libslirp) is the only default,
as designed. Bridged networking needs a privileged helper and stays a later
feature behind an explicit opt-in.

### `QEMU-VSOCK-MACOS` — CONFIRMED 2026-08-19 — design already routed around it
`-device help` lists no vsock devices of any kind. The guest agent uses
`virtio-console` and ADB uses TCP, so nothing in the critical path is affected.

---

## Confirmed in Milestone 2

### `HVF-ENTITLEMENT-SET` — CONFIRMED 2026-08-19 — **decisive**
`com.apple.security.hypervisor` alone, on an **ad-hoc** signature, is sufficient
to use Hypervisor.framework. Nothing further is required for local development.

*Evidence:* `multiemu-hvprobe`, run twice on the same binary.

| Signature | `hv_vm_create` |
| --- | --- |
| SwiftPM default (`com.apple.security.get-task-allow` only) | `HV_DENIED` |
| ad-hoc + `com.apple.security.hypervisor` | `HV_SUCCESS` |

With the entitlement the probe went further and **executed guest code**:
`hv_vm_map` mapped a 16 KiB page at guest physical 0, `hv_vcpu_create`
succeeded, `hv_vcpu_run` returned `HV_EXIT_REASON_EXCEPTION` with ESR exception
class `0x16` (HVC64), and guest `x0` read back as `42` — the value the guest
program placed there. `hv_vcpu_run` wall time: **0.009 ms**.

*Consequences:* hardware virtualization is usable from a Multiemu-signed binary;
the QEMU helper needs exactly this one entitlement; and the native-VMM option is
proven real rather than theoretical.

### `AMFI-ENTITLEMENTS-NO-COMMENTS` — CONFIRMED 2026-08-19
An entitlements `.plist` containing XML comments **fails to sign**:

```
Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 10
```

`plutil -lint` accepts the same file, so the failure appears only at signing
time. All Multiemu entitlements plists are therefore comment-free, and their
rationale lives in `Resources/entitlements/README.md`.

### `VZ-VIRTIO-GPU-3D` — CONFIRMED 2026-08-19 — **justifies the backend choice**
Virtualization.framework exposes **no** API to attach a 3D renderer.

*Evidence:* `multiemu-vzprobe` reads the Objective-C property list of the
graphics classes off the running system:

| Class | Complete public property surface |
| --- | --- |
| `VZVirtioGraphicsDeviceConfiguration` | `scanouts` |
| `VZVirtioGraphicsScanoutConfiguration` | `widthInPixels`, `heightInPixels` |

No property on any graphics configuration class matches `3d`, `accel`, `render`,
`virgl`, `venus`, `gfxstream`, `opengl`, `metal` or `gpu`. A virtio-gpu device
whose only configuration is a scanout size is a 2D framebuffer.

*Consequence:* Android under Virtualization.framework would software-rasterise
its entire UI. QEMU remains the primary backend.

### `VZ-SAVE-RESTORE` — CONFIRMED 2026-08-19
Save/restore exists and works for a Linux device set.

*Evidence:* `VZVirtualMachine` exposes `saveMachineStateToURL:completionHandler:`
and `restoreMachineStateFromURL:completionHandler:`, and
`validateSaveRestoreSupport()` returned **supported** for a configuration with
`VZLinuxBootLoader`, a virtio console serial port, a virtio entropy device and a
NAT network device.

### `VZ-VALIDATE-IGNORES-KERNEL-FILE` — CONFIRMED 2026-08-19 — **actionable**
`VZVirtualMachineConfiguration.validate()` succeeds with a kernel URL pointing at
an **empty** file and with one pointing at a **non-existent** path.

*Consequence:* Apple's validation is a configuration check, not an image check.
Multiemu's image manager must verify existence, size and SHA-256 itself before
any boot; otherwise a missing image surfaces as an unexplained boot failure.

### `HV-GIC-API` — CONFIRMED 2026-08-19 — **revises a cost estimate**
macOS 15 ships a complete in-kernel GICv3 API. The SDK contains `hv_gic.h`,
`hv_gic_config.h`, `hv_gic_parameters.h`, `hv_gic_state.h` and `hv_gic_types.h`,
annotated `API_AVAILABLE(macos(15.0))`, providing `hv_gic_create`,
distributor/redistributor base configuration, MSI region configuration, ICC/ICH/ICV
register access, and GIC **state** access for save/restore.

*Consequence:* the interrupt controller — the largest single component of a
from-scratch arm64 VMM — is supplied by the OS. `BACKEND-EVALUATION.md` §3 is
revised accordingly. This does not make the native VMM the right first backend;
it makes it a materially cheaper future option than previously stated.

### `VZ-MEMORY-LIMITS` — CONFIRMED 2026-08-19
`VZVirtualMachineConfiguration` reports minimum 4.0 MiB / maximum **16.00 GiB**
memory and 1–64 CPUs on this host. The maximum equals installed physical RAM, so
it is a host-dependent figure and must be read at runtime rather than assumed.

---

## Confirmed in Milestone 1

### `HOST-SYSCTL-KEYS` — CONFIRMED 2026-08-19
`kern.hv_support`, `kern.hv_vmm_present`, `hw.optional.arm64`, `hw.memsize`,
`hw.logicalcpu`, `hw.physicalcpu`, `hw.perflevel0.physicalcpu`,
`hw.perflevel1.physicalcpu`, `hw.pagesize`, `machdep.cpu.brand_string`,
`hw.model`, `hw.cachelinesize`, `hw.cpufamily`, `vm.swapusage` all exist and
parse. On this host `kern.hv_support = 1`, `kern.hv_vmm_present = 0`.

### `VZ-IS-SUPPORTED-API` — CONFIRMED 2026-08-19
`VZVirtualMachine.isSupported` exists and returns `true`.

### `NESTED-VIRT-API` — CONFIRMED 2026-08-19
`VZGenericPlatformConfiguration.isNestedVirtualizationSupported` exists on
macOS 15+ and returns **`true`** on Apple M5. The corresponding instance
property `nestedVirtualizationEnabled` is present on
`VZGenericPlatformConfiguration`. No planned Multiemu feature requires it.

### `ROSETTA-AVAILABILITY-CASES` — CONFIRMED 2026-08-19
`VZLinuxRosettaAvailability` has cases `.notSupported`, `.notInstalled`,
`.installed`; `.installed == rawValue 2` on a host with Rosetta present.

### `SEC-CODE-SIGNING-INFO` — CONFIRMED 2026-08-19
`SecCodeCopySelf` → `SecCodeCopyStaticCode` → `SecCodeCopySigningInformation`
with `kSecCSSigningInformation | kSecCSRequirementInformation` returns
`kSecCodeInfoIdentifier`, `kSecCodeInfoFlags` and `kSecCodeInfoEntitlementsDict`.

---

### `CUTTLEFISH-WITHOUT-CVD` — CONFIRMED 2026-08-20 — **M4 gate, answered YES**
A Cuttlefish image reaches `sys.boot_completed = 1` under plain QEMU with no
`cvd` launcher, no crosvm and no vsock transport. Image
`aosp_cf_arm64_only_phone-img-15660610` on
`qemu-system-aarch64 -machine virt -accel hvf -smp 8 -m 4096`:

| Signal | Value |
| --- | --- |
| `sys.boot_completed` / `dev.bootcomplete` | `1` / `1` at **16 s** uptime |
| `init.svc.bootanim` | `stopped` |
| Registered binder services | 332 |
| Resumed activity | `com.android.launcher3/.uioverrides.QuickstepLauncher` |
| Guest build | Android 17, SDK 37 |
| Stability | `system_server` still on its first pid at 246 s |
| Visual proof | 1920x1080 `screencap` of the rendered lock screen |

Four things had to be right, and each one *looks* like host coupling without
being it:

1. **`androidboot.vsock_lights_port` must be >= 1024.** The lights HAL is a
   vsock *server*. Unset, it parses port 0; Linux reserves vsock ports <= 1023
   for `CAP_NET_BIND_SERVICE`, which the HAL's `.rc` drops (`user nobody`, no
   `capabilities` line), so `bind()` returns EACCES. Nothing ever connects to
   the port — binding and listening is all it needs. `socket(AF_VSOCK)` itself
   succeeds because af_vsock is in the guest kernel and `bind(VMADDR_CID_ANY)`
   needs no transport.
2. **virtio-console ports.** uwb, oemlock and sensors are handed `/dev/hvc9`,
   `/dev/hvc10` and `/dev/hvc18`; without a virtio-serial bus they fail on
   ENOENT.
3. **The sensors HAL needs an answer, not just a device.** It speaks goldfish
   `qemud` over hvc18 — `[u32 type][u32 len][len bytes]`, first command
   `list-sensors` — and aborts with `Can't parse qemud response` unless the
   reply payload is an ASCII decimal bitmask. `"0"` (no sensors) is enough.
4. **An `frp` partition must exist.** `PersistentDataBlockService` opens
   `ro.frp.pst` on a worker thread; with no partition the thread never signals
   and `onBootPhase(500)` throws `PersistentDataBlockService init timeout` after
   ten seconds, which is fatal to `system_server`. The guest reaches a full
   framework, dies and restarts forever, and **no log names the partition**.

*Consequence:* Cuttlefish images are usable guests for this project. An earlier
reading of the same symptoms — that these HALs require the Cuttlefish host stack
over vsock, and that the image family therefore had to change — was wrong.

*Not required for boot, still failing:* `vendor.threadnetwork_hal`
(`Check failed: node_id > 0`) and `vendor.ril-daemon`. Neither blocks
`boot_completed`.

*Bring-up only:* `audit=0` on the kernel command line. With
`androidboot.selinux=permissive` this image loses ~44k audit records per boot,
and the flood costs enough CPU to push services past watchdog timeouts —
time-to-311-services went from ~200 s to 16 s when audit was silenced.

### `COLD-BOOT-TIME` — CONFIRMED 2026-08-21 — **target met**
Cold boot to `sys.boot_completed`, measured per `PERFORMANCE-METHODOLOGY.md`.
Image `cuttlefish-arm64-15660610`, Android 17, 4 vCPU, 4 GiB, audit at its
default (on), host M-series Mac.

**Through the product path** — `multiemu-session` driving `EmulatorSession` and
`QEMUBackend`, so the backend builds the command line, allocates the console
sockets and starts the responders itself. Timed by the session's own boot probe
(`androidBootCompleted`), five sequential runs with a graceful shutdown between
each (confirmed distinct: the guest's f2fs checkpoint version advances every
run, and each session ends `Stopped`):

| | |
| --- | --- |
| Runs | 3.554, 3.441, 3.458, 3.291, 3.582 s |
| **Median / worst** | **3.46 s / 3.58 s** |
| Target | <= 45 s (60 s max) — **PASS, with ~13x headroom** |

**First boot**, factory-fresh userdata, same path: **5.58 s**. The very next boot
on that userdata measured 3.47 s, in line with the median above, so the one-time
work costs ~2.1 s and does not carry over. `PERFORMANCE-METHODOLOGY.md` sets no
target for first boot; it is recorded because it is the figure a user meets once.

QEMU spawn and kernel load add 0.1–0.2 s on top, measured separately.

**An earlier figure of 8.5 s was wrong, and the reason is worth recording.** It
was measured with a hand-written script rather than through the backend, and
that script attached no `virtio-rng` device. Without one the guest blocks on
entropy during early boot — the exact failure the comment at
`QEMUCommandBuilder.swift` (`--- Entropy ---`) exists to prevent. The result was
a number for a configuration the product does not ship, roughly 5 s slower than
the product. Any figure produced by driving QEMU directly should be treated as
unrepresentative until reproduced through `EmulatorBackend`.

*Superseded rows, kept as a record of the discrepancy:* the same image measured
8.5 s median / 8.6 s worst (5/5) with the hand-rolled command line and a Python
responder, 8.6 s with the shipping responder, and 8.8 s after the responder
rewrite — all of them missing the RNG. First boot on factory-fresh userdata
measured 10.9 s under that same handicap — against 5.58 s through the product
path, so the RNG-less command line roughly doubled it, consistent with the
warm-boot discrepancy.

**Measurement notes, because three of these produced wrong answers first.**

- *Do not probe the guest console to detect boot.* The console shell is a
  service participating in the boot; each reconnect hangs it up and init
  restarts it. Polling `getprop` every second reported two of three runs as
  240 s timeouts on guests that had booted in under 26 s. Detection reads init's
  own `processing action (sys.boot_completed=1)` line from the kernel console,
  or the session's `androidBootCompleted` probe.
- *Console polling also inflated the figure* by ~4 s of lag: one boot measured
  12.8 s by polling and 8.5 s from the log line.
- *QMP `system_powerdown` does not shut Android down on `virt`.* It raises an
  ACPI power-button event, which Android renders as a power-off dialog, so QEMU
  never exits and the next run starts on a dirty f2fs. `reboot -p` on the guest
  console, or the session's own graceful shutdown, is the real thing.

*Deviations from the documented procedure:* no Mac reboot or login-item settling
beforehand, and runs were back-to-back.

*Precondition:* the guest does not reach `boot_completed` at all without a
responder answering the sensors protocol on its console port, nor without a GPU
— `GuestDisplayMode.headless` emits no display device, and both SurfaceFlinger
and zygote abort with "couldn't find an OpenGL ES implementation". An Android
guest needs `.attached`.

### `IDLE-CPU-BOTTLENECK` — CONFIRMED 2026-08-25 — **target met after a fix**
Idle host CPU sat on its 10% target (9.0%, 10.0%, 10.2% across runs) with no
attribution beyond "it is `qemu-system-aarch64`". It is now **7.4% and 7.5%**
across two full-methodology runs.

*How it was located:* `sample <pid> 15` on a settled guest. All four `CPU N/HVF`
threads were in `hv_trap` — executing guest code — while QEMU's main loop sat in
`g_poll` for 12250 of 12382 samples and the `gdbus` and worker threads were
idle. The cost was inside Android, not in the emulator.

*Cause:* two HALs crash on start and Android's init restarts them about once a
second, forever. Both are host capabilities that do not exist here:

| Service | Guest's own words | Why it cannot be satisfied |
| --- | --- | --- |
| `vendor.ril-daemon` | `'ro.boot.modem_simulator_ports' must be an integer vsock port for the modem simulator` | `qemu-system-aarch64 -device help` lists **no vsock device** in this build |
| `vendor.threadnetwork_hal` | `Check failed: node_id > 0`, then `utilsInitSocket() at simul_utils.c:370: Failure` | its `ot-rcp` radio binds to `eth1`, which this guest does not have |

*Controlled experiment*, all within one guest so that guest age cannot explain
it — note the control is the oldest and the most expensive sample:

| Same guest, in order | Idle CPU |
| --- | --- |
| Both crash-looping | 10.2% |
| Both stopped | 8.8% |
| Also `seriallogging` stopped | 8.2% |
| All three started again (control) | 11.1% |

*Fix:* `GuestServiceQuiesce`, run by `QEMUBackend` on its boot-completed
transition, which stops a listed service **only when `init.svc.<name>` reads
`restarting`**. Verified live: the harness prints `guest services: stopped
vendor.ril-daemon, vendor.threadnetwork_hal` and each stop is confirmed by
re-reading the property rather than assumed.

*Rejected:* `androidboot.openthread_node_id=1`. It measured 9.5% against a
10.2% baseline and looked like a fix; the service was still `restarting`, and at
equal guest age the same argument measured **11.3%** — worse, because each
restart now forks `ot-rcp` before dying. A metric that moves is not a mechanism
that works.

*Not taken:* Cuttlefish's `seriallogging` streams every log line at verbosity
`V` to a console port this host backs with `null`, worth a further ~0.6 points.
It is working as designed, so the crash-loop rule does not reach it and it is
left alone.

### `GUEST-CONSOLE-SERVICES` — CONFIRMED 2026-08-20
An Android guest built for a virtual board expects a bank of virtio-console
ports and hands one to each HAL that talks to a host service. Two failure modes,
and the second is much the worse:

- A **missing** port fails its HAL on `ENOENT`. Noisy and easy to read.
- A port that **exists but never answers** leaves the HAL blocked in `read()`,
  so it never registers its interface — and because the interface is declared in
  VINTF, `system_server` then waits on it for the life of the boot. Nothing in
  any log names the port.

`MultiemuGuestServices` answers them. `QEMUBackend` allocates a socket per port
that needs a service, passes it to QEMU as a `virtconsole` chardev, starts a
`GuestConsoleResponder` once QEMU is up, and stops it on every exit path.

Verified against `cuttlefish-arm64-15660610`: with the sensors port answered,
`sys.boot_completed=1` at 8.58 s, `android.hardware.sensors.ISensors` registered,
333 binder services, `com.android.launcher3` resumed. With it unanswered the
same image never completes boot.

**This is a security boundary.** The bytes decoded here are produced inside the
guest. The frame's length word is a number the guest chooses and would otherwise
size a host allocation, so it is bounded (`QemudFrame.maximumPayloadBytes`)
before it is used for anything, and a refused length drops the connection rather
than trying to resynchronise a stream at an unknown offset. A guest command is
only ever matched against a fixed vocabulary to select a constant reply; it
never reaches a shell, a path, or a format string.

**The first implementation was not sound, and an adversarial review found it.**
Recorded because the defects were not visible by reading the code, and three of
them were reproduced against the shipped binary:

| Defect | Consequence | Fix |
| --- | --- | --- |
| `write` with no `SO_NOSIGPIPE` | A guest closing the port with a request unanswered killed the **host process** with SIGPIPE — and a guest closes this port on every reboot | `SO_NOSIGPIPE` on the socket; regression test sends 200 requests then closes with `SO_LINGER{1,0}` |
| Reads yielded into an unbounded `AsyncStream` | Guest bytes queued *ahead of* the decoder, so its cap bounded nothing: 400 MiB of legal empty frames grew host RSS by 415 MB | Read, decode and reply in sequence on one thread — backpressure by construction, not by a buffer size |
| Blocking `write` while actor-isolated | A guest that sent requests and never read replies pinned the actor and deadlocked `stop()` and device shutdown | Replies are written on the owning thread |
| Actor closed a descriptor its reader thread was using | The freed number was reissued to the next socket, so one connection read another's traffic (~8% of start/stop cycles) | The worker owns the descriptor for its whole life; `stop()` uses `shutdown(2)` to wake the read, and only the worker closes |
| Buffer cap measured on arriving bytes | The decoder rejected maximum-size frames it advertises as legal whenever anything was pipelined behind them | Cap measured on the residue after complete frames are drained |
| `isRunning` never reset after the fault budget | `start()` silently did nothing afterwards; the port stayed dead for the process lifetime | Reset in a `defer` covering every exit from the serve loop |
| `handleExit` did not stop responders | A guest that powered itself off left responders running, and they accumulated across runs — while a doc comment claimed the opposite | `stopConsoleResponders()` on the exit path, and before each start |
| Port socket files never unlinked | One leaked file per port per run | Paths tracked and removed with the responders |

*Lesson worth keeping:* the deadlock was "fixed" once by moving reads off the
actor while leaving writes on it and the descriptor shared. Splitting ownership
of a file descriptor between a thread and an actor is the defect; moving one
side of the split does not repair it.

**A second review of the rewrite found the hole had moved, not closed.** The
single-owner descriptor design itself was verified sound — 60 sequential
start/stop cycles with no hang and no descriptor leak (5 open before, 5 after),
`shutdown(2)` waking a parked read in 58 microseconds worst case, and the
continuation resumed exactly once. The wiring was verified against real QEMU
11.1.0: `info qtree` reports `chardev hvcN => nr = N` for all 19 ports, so the
array index genuinely is the guest's `/dev/hvcN`. What was still wrong:

| Defect | Consequence | Fix |
| --- | --- | --- |
| `stop()` cleared `isRunning` and `task` **before** awaiting | An overlapping `start()` passed the guard and resurrected the loop `stop()` was waiting on: two serve loops, a `stop()` that never returned, and a worker orphaned with its descriptor open | `task` stays set across the await; a generation token keys the serve loop, so a dying run cannot clobber a newer one |
| `faultsSeen` never reset | A responder that spent its budget was dead for the life of the object while `start()` still reported success — and `QEMUBackend` holds one per port for the whole run | Reset per run; **and the test named for this never spent the budget**, so it passed vacuously. It now sends five oversized frames |
| `bank(count:services:)` silently dropped an out-of-range service | `--console-ports 10 --sensors-port 18` gave ten silent ports, no responder, no warning — and a guest stall reported only as `bootTimedOut`, naming nothing | Throws instead |
| `escapeOptionValue` missing on `-drive file=`, `-serial unix:`, `-qmp unix:` | A device directory named e.g. `Pixel 6, API 37` splits the option and QEMU opens the wrong path | Escaped, with tests |
| Sensors reply vocabulary was invented | Goldfish sends **nothing** for `set:`/`set-delay:`/unknown and echoes `wake`; replying "OK" injects a frame into the stream the HAL reads events from | Faithful vocabulary, matched **exactly** rather than by prefix. Re-verified live: boot completes, 0 sensor aborts, 0 qemud parse failures |
| `requestStop()` could `shutdown` a closed descriptor number | Narrow window between the worker closing and the actor noticing | `close` and `shutdown` interlocked under the worker's lock |

*Also corrected:* `EINTR` was treated as a peer close; it is now retried.

*Since fixed, and verified by reproducing the stall:* responder health is
reported. A run with twenty console ports and the sensors port left unanswered
now fails with

    [bootTimedOut] The guest did not finish booting within 45 seconds.
    Last recognised milestone: androidZygoteStarted. Guest console ports — 20
    present but none answering a protocol; a HAL waiting on one will block the
    boot.

where it previously said only "Last recognised milestone: androidZygoteStarted."
The healthy path is unchanged: 3.750 s, zero sensor aborts.

The mechanism: `GuestConsoleResponder` takes an
observer and reports `.serving`, `.couldNotConnect` or `.gaveUp`; `QEMUBackend`
routes those through `handleBackendMessage`, so they reach the event stream and
the failure detail rather than only the log. A boot timeout now also carries a
line per console port — whether it is serving, how many replies it has sent and
how many faults it has seen. A sensors port that has answered nothing while the
guest was booting is the single most useful fact about a stalled Android boot,
and it is not recoverable from the console log.

*Design note:* which `/dev/hvcN` carries which protocol is a property of the
image, so it is declared by the caller in `GuestStartRequest.consolePorts`
rather than baked into the backend.

*Bring-up tool:* `multiemu-guest-service --sensors <socket>` serves the same
component against a QEMU started by hand, which is what working out a new
image's expectations needs.

## Open — and now partly out of scope by decision

**Multiemu ships unsigned** (MIT, no Apple Developer membership — see
`docs/RELEASE.md`). Signing and notarization are therefore not steps this
project is waiting to take. What remains genuinely open below is the part that
does *not* depend on a signature: whether a QEMU built from pinned source can be
bundled with its dylibs relocated correctly.

### `QEMU-BUNDLING` — OPEN — **can still invalidate the shipping story**
*Claim:* a QEMU we build from source can be bundled inside the app with all of
its dylibs resolved, and run from there.
*Not part of the claim any more:* Developer ID signing and notarization of that
QEMU. An unsigned release does not need them, and the ad-hoc signing the build
already applies is enough for the app to launch its own helper.
*Advanced:* the signing pipeline is proven (`scripts/sign-helper.sh`,
`HVF-ENTITLEMENT-SET`); `scripts/build-qemu.sh` implements
fetch/configure/build/bundle with dylib relocation.
*Still needed:* a real build from pinned source, bundled and launched from
`Contents/Helpers/`. That is testable here and simply has not been done.
*Note:* the Homebrew binary cannot answer this — it links dozens of dylibs from
`/opt/homebrew` that are neither ours to sign nor relocatable. That is precisely
why `build-qemu.sh` exists.

## Open — later milestones

### `ANDROID9-VIRTIO` — OPEN
Does Android 9 boot on a pure virtio device model, without goldfish devices?

### `AOSP-IMAGE-REDIST` — OPEN — **legal**
Per-artifact confirmation of redistribution terms; legal review before release.

---

## Verified without the dependency being present

### `BOOT-HARNESS` — CONFIRMED 2026-08-19
The Milestone 2 boot harness is correct independently of QEMU. `multiemu-boot`
was driven against `Tests/Fixtures/fake-qemu.sh`, which replays recorded guest
console streams:

| Scenario | Result | Exit code |
| --- | --- | --- |
| Successful Linux boot | 4 milestones timed; terminated on `userspaceReady` | 0 (PASS) |
| Kernel panic | `kernelPanic` reported as the cause, not as progress | 2 (FAIL) |
| Silent hang | watchdog fired at 4.099 s for a 4 s timeout | 3 (TIMEOUT) |

Process spawn, line buffering across partial reads, milestone recognition,
first-occurrence timing, terminate-on-terminal-milestone and the watchdog are
all exercised. When QEMU arrives, only QEMU itself is unverified.

### `QEMU-PROCESS-ENVIRONMENT` — CONFIRMED 2026-08-19
`QEMUProcess` gives the child a minimal environment (`PATH` only) and does not
inherit the parent's. Verified by the fixture's scenario selection failing until
it was moved from an environment variable to argv.
*Consequence:* backend behaviour cannot be perturbed by a developer's shell or by
`DYLD_*` variables. Anything QEMU genuinely needs must be added explicitly.

