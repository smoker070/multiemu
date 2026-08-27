# Performance methodology

The product targets are acceptance criteria, not aspirations. This document
defines how each is measured so that a number in a milestone report is
reproducible and means the same thing every time.

**Rule: no target may be reported as met without the measurement that proves it,
and every measurement must separate host application overhead from guest
workload wherever the tooling allows.**

---

## 1. Targets

| Metric | Target | Hard floor |
| --- | --- | --- |
| Cold boot (initialized device) | ≤ 45 s | 60 s |
| First boot (new device) | measured separately | no target |
| Sustained frame rate | 60 FPS preferred | 30 FPS minimum |
| Frame pacing | stable | a nominal FPS reached with severe stutter is a **fail** |
| Idle host CPU | < 10% of one logical core | — |
| Guest RAM default | 4 GiB | 2 GiB minimum profile |
| Storage default | 32 GiB sparse | — |
| Default display | 1920×1080 landscape | — |

If profiling shows a target is unreachable for a documented architectural
reason, the evidence and a revised target go in the milestone report. The target
is not quietly dropped.

---

## 2. Instrument: signposts

Every measured operation emits an `OSSignposter` interval under subsystem
`com.multiemu.Multiemu`. Names are constants in
`Sources/MultiemuSupport/Signposts.swift`.

| Signpost | Interval measured |
| --- | --- |
| `host.capability.probe` | Host detection cost at launch |
| `backend.launch` | Spawn → backend reports ready |
| `guest.cold.boot` | Backend ready → `sys.boot_completed = 1` |
| `guest.first.boot` | Device creation → first `sys.boot_completed = 1` |
| `guest.first.frame` | Backend ready → first frame presented |
| `graphics.frame.submit` | Per-frame: command receipt → Metal present |
| `snapshot.save` / `snapshot.restore` | Full snapshot operation |
| `packages.apk.install` | `install` invoked → package manager confirms |

Collection:

```bash
xcrun xctrace record --template 'Time Profiler' --launch -- .build/debug/multiemu-probe
log stream --predicate 'subsystem == "com.multiemu.Multiemu"' --style compact
```

---

## 3. Per-metric procedure

### Cold boot

**Definition.** From the user's launch action to `getprop sys.boot_completed`
returning `1`. Includes backend spawn and kernel boot. Excludes first-boot work.

**Procedure.** Device already initialized (at least one prior successful boot).
Reboot the Mac, wait 3 minutes for login-item settling, then 5 consecutive runs
with a full shutdown between each. Report median and worst.

**Attribution.** `backend.launch` isolates our spawn overhead;
`guest.cold.boot` minus `backend.launch` is guest kernel + userspace time.
Kernel timing comes from the guest's own `dmesg` timestamps, and Android's
`boot_progress_*` events come from `logcat -b events`, which attributes the
remainder to Android rather than to us.

### First boot

Same instrumentation, `guest.first.boot`. Measured on a freshly created device,
5 runs, each on a new device. Reported separately and never blended into the
cold-boot figure.

### Frame rate and pacing

**Definition.** Frames presented to the Metal layer per second, plus the
distribution of frame intervals.

**Procedure.** Fixed workload — the same scripted UI interaction and the same
scrolling test — for 60 seconds after boot settles.

**Reported.** Mean FPS, p50/p95/p99 frame time, count of frames over 33.3 ms
(dropped at 30 FPS) and over 16.7 ms (dropped at 60 FPS), and the longest single
frame.

**Pass condition.** Sustained FPS ≥ 30 **and** p99 frame time < 2× p50. Mean FPS
alone never passes this metric — that is what "reaching a nominal FPS target
while exhibiting severe stutter does not count as success" means numerically.

Guest-side cross-check: `dumpsys SurfaceFlinger --latency` and
`dumpsys gfxinfo <package>` to distinguish "the guest never produced the frame"
from "we failed to present it".

### Input latency

**Definition.** Host event timestamp → guest-visible response.

**Procedure.** Instrument the input path with signposts at host event receipt
and at guest injection; add a guest-side timestamp via `getevent`. End-to-end
photon latency needs a high-speed camera and is out of scope; the measurable
portion is host-event → guest-input-event, and it is reported as exactly that.

### Idle CPU

**Definition.** Host CPU consumed by all Multiemu processes combined, as a
percentage of one logical core, after the guest reaches stable idle.

**Procedure.** Boot, wait 120 s, then sample every second for 300 s. Report mean
and p95. Brief guest background bursts are excluded by reporting the median of
30-second windows alongside the mean.

**Attribution.** `ps -o %cpu` per process, so the app, the backend and the
renderer are attributed separately. A 9% total that is 8% renderer is a
different engineering problem than 8% backend.

### Memory

`footprint -p <pid>` for each process, plus the guest's own `dumpsys meminfo`.
Reported as: application RSS, backend RSS, renderer RSS, and guest-allocated
memory. Host total must be compared against the configured guest RAM — a 4 GiB
guest whose backend holds 7 GiB resident is a defect.

### Disk I/O

`fs_usage -f filesys -p <pid>` during boot and during a scripted app install.
Reported as bytes read/written and operation count. Sparse allocation is
verified separately with `du -h` (allocated) versus `ls -l` (logical) on
`userdata.qcow2` — the two must differ, or sparse allocation is not working.

### Snapshot duration

`snapshot.save` / `snapshot.restore` intervals, 5 runs each, on a device with a
known guest state. Reported with the resulting snapshot file size.

### APK installation

`packages.apk.install`, measured with a fixed test APK of a stated size, 5 runs,
reported with the APK size because the number is meaningless without it.

---

## 4. Reporting format

Every milestone that touches performance appends to `reports/`:

```json
{
  "milestone": "M4",
  "date": "2026-01-01",
  "host": { "...": "output of multiemu-probe --format json" },
  "guest": { "image": "...", "androidVersion": "...", "architecture": "arm64" },
  "measurements": [
    { "metric": "coldBoot", "unit": "s", "runs": [41.2, 43.8, 40.9, 44.1, 42.0],
      "median": 42.0, "worst": 44.1, "target": 45, "verdict": "PASS" }
  ]
}
```

The host block is the probe's JSON output verbatim. A measurement without its
host context cannot be compared against anything.

---

## 5. Rules

1. Correctness before optimization. A milestone's functional criteria pass
   before its performance criteria are even measured.
2. Baseline before change. No architectural change is made for performance
   without a prior measurement of the thing being changed.
3. Debug builds are never used for performance numbers. Release configuration
   only, stated in the report.
4. Five runs minimum. Single runs are anecdotes.
5. Report the worst case, not only the median. Users experience the worst case.

## 6. The harness

`multiemu-perf` runs the measurements and writes the report. It is a product
binary, not a script, for one specific reason: its QEMU command line comes from
`QEMUCommandBuilder`, the same builder the emulator uses.

**Never measure through a hand-written QEMU command line.** A scratch command
line used earlier omitted `virtio-rng`; the guest blocked on entropy and the
cold-boot figure came out 2.5x the product's. The number was reproducible,
stable across five runs, and described a configuration that does not ship.

Statistics come from `MultiemuSupport.PerformanceStatistics`, which has tests.
Percentiles are nearest-rank, so every reported value is one the system actually
produced rather than an interpolation between two samples that were never
observed.

Two measurement traps this harness hit, both of which produced confident wrong
numbers before they were found:

- **`ps -o %cpu` on macOS is an average over the process's whole lifetime.**
  Sampling it after a settle reports the boot, not the idle. An "idle" guest
  measured 58% that way. CPU is now accumulated CPU time differenced between
  samples, which is the share of one core over the interval just elapsed.
- **A workload injected outside the display area does nothing.** A scroll
  scripted at y=1400 on a 1080-tall guest never landed, the screen blanked on
  inactivity, and the run recorded a 59-second gap between frames as though it
  were pacing data. The gesture now asks the guest for its geometry first.

Boot is detected from the guest's own `sys.boot_completed` console line, never
by asking a shell — the console shell is a service participating in the boot,
and probing it perturbs the thing being measured.

**A frame-rate workload has to be driven inside the guest.** Synthetic touches
injected at the display cannot dismiss a keyguard or open an app, so they
measure a lock screen: 424 frames over 19% of the window. The same harness
driving the guest over ADB — keyguard dismissed, a scrollable app in front,
`input swipe` through Android's own injection path — measured 2607 frames over
100% of the window. Report frame **coverage** alongside any rate; below about
half, the number describes idleness rather than throughput.

**Blocking calls belong on their own thread.** `ADBClient.shell` is synchronous.
Looping it inside a `Task` held a cooperative thread for the whole run, starved
the executor, and the harness died mid-measurement without writing a report.
Same shape as reading a socket inside an actor.

## 7. Finding the idle-CPU bottleneck

Idle CPU sat on its 10% target for three runs (9.0%, 10.0%, 10.2%) with no
attribution: the per-process table named `qemu-system-aarch64` and nothing else,
which is true and useless. What follows is how it was actually found, because
the first two answers were both wrong.

**Per-process totals cannot say where the time goes. Sample the stacks.**
`sample <pid> 15` on the running guest split it immediately: all four
`CPU N/HVF` threads spent their samples in `hv_trap` — *inside* the guest — and
the QEMU main loop was in `g_poll` for 12250 of 12382 samples. Whatever was
spending the CPU was Android, not the emulator. That one observation moved the
search from profiling QEMU to asking the guest.

**Do not sum `ps -M` rows.** A first pass added the per-thread CPU deltas and
got 22% for a process whose own accumulated time differenced to 11.2% over the
same kind of window. The process-level delta and the sampler agreed with each
other and with the harness; the hand-summed thread table did not. Per-thread
attribution is for *shape* — which thread is busy — and the sampler gives that
more reliably.

**The guest was not idle.** With ADB up, `top` inside the guest showed `init`
and `servicemanager` near the top of an otherwise quiet device, and `logcat`
showed why: two HALs that cannot work on this host — `vendor.ril-daemon` and
`vendor.threadnetwork_hal` — crash on start, and Android's init restarts them
about once a second, forever. Each cycle forks a process, fails, writes a crash
to the log, and the Cuttlefish `seriallogging` service serialises every line of
it to a console port. `getprop init.svc.<name>` reports both as `restarting`.

**A number that moved is not a mechanism that worked.** The Thread HAL's first
error is `Check failed: node_id > 0`, and its binary reads
`ro.boot.openthread_node_id`. Adding `androidboot.openthread_node_id=1` produced
a 9.5% run against a 10.2% baseline, which looks like a fix and is not one: the
service was still `restarting`, and measured against a guest of the same age the
argument scored **11.3%** — slightly worse, because each restart now gets
further (it forks `ot-rcp`, which dies in `utilsInitSocket()` binding to an
`eth1` this guest does not have) before dying. The apparent gain was run-to-run
variation. **Confirm the mechanism, not just the metric**: here that meant
reading `init.svc.<name>` and the crash line, not re-reading the CPU figure.

**A/B inside one guest, with the control run last.** Guest age is a confound —
Android does background work for minutes after boot — so comparing two runs at
different ages proves nothing. The sequence that settled it stopped the services
in a live guest, measured, then started them again and measured a third time:

| Same guest, in order | Idle CPU |
| --- | --- |
| Both services crash-looping | 10.2% |
| Both stopped | 8.8% |
| Also `seriallogging` stopped | 8.2% |
| All three started again (control) | **11.1%** |

The control is the part that matters. It is the *oldest* sample and the most
expensive, which rules out settling as the explanation and leaves the loops.

**Neither service can be made to work here, and that is a host fact, not a
guess.** `vendor.ril-daemon` needs the Cuttlefish modem simulator over vsock and
`qemu-system-aarch64 -device help` lists no vsock device at all in this build.
The Thread HAL needs a simulated radio bound to an interface the guest does not
have. So the fix is to stop them — `GuestServiceQuiesce`, which stops only a
service init reports as `restarting`, so an image or host where they work is
left alone.

Result, full methodology, with the quiesce running as product behaviour:
**idle CPU 7.4%**, against 10.2–10.4% before.
