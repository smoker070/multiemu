import Foundation
import Testing
@testable import MultiemuBackend

@Suite("Guest boot probe")
struct GuestBootProbeTests {

    /// Feeds lines at one simulated second apart.
    private func run(_ lines: [String]) -> GuestBootProbe {
        var probe = GuestBootProbe()
        for (index, line) in lines.enumerated() {
            _ = probe.consume(line: line, elapsed: .seconds(index))
        }
        return probe
    }

    @Test("A generic Linux boot is recognised end to end")
    func linuxBoot() {
        let probe = run([
            "[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x611f0000]",
            "[    0.000000] Linux version 6.6.0 (builder@host)",
            "[    1.204000] Freeing initrd memory: 8192K",
            "[    1.500000] Run /init as init process",
            "Welcome to Alpine Linux 3.20",
        ])
        #expect(probe.hasSucceeded)
        #expect(!probe.hasFailed)
        #expect(probe.elapsed(for: .kernelStarted) == .seconds(0))
        #expect(probe.elapsed(for: .userspaceReady) == .seconds(4))
    }

    @Test("An Android boot is recognised end to end")
    func androidBoot() {
        let probe = run([
            "[    0.000000] Booting Linux on physical CPU 0x0000000000",
            "[    2.100000] init: init first stage started!",
            "[    9.300000] init: Starting service 'zygote'...",
            "[   31.700000] init: setprop sys.boot_completed 1",
        ])
        #expect(probe.hasSucceeded)
        #expect(probe.elapsed(for: .androidInitStarted) == .seconds(1))
        #expect(probe.elapsed(for: .androidBootCompleted) == .seconds(3))
    }

    @Test("A kernel panic is a failure, never progress")
    func kernelPanic() {
        let probe = run([
            "[    0.000000] Booting Linux on physical CPU 0x0000000000",
            "[    3.100000] Kernel panic - not syncing: VFS: Unable to mount root fs",
        ])
        #expect(probe.hasFailed)
        #expect(!probe.hasSucceeded)
        #expect(probe.isFinished)
        // The panic line also contains "Unable to mount root fs"; the panic
        // pattern is checked first so the reported cause is the panic itself.
        #expect(probe.milestones.last?.kind == .kernelPanic)
    }

    @Test("An initramfs emergency shell is a terminal success, named distinctly")
    func initramfsShell() {
        // Observed for real in Milestone 2: Alpine's netboot initramfs cannot
        // find boot media when no disk is attached, and drops to a shell. The
        // kernel, the accelerator and the virtio path all worked, so the
        // harness must call this a success — but never confuse it with a
        // completed system boot.
        let probe = run([
            "[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x610f0000]",
            "[    0.221263] Mounting boot media...",
            "[    5.258865] Mounting boot media: failed. ",
            "initramfs emergency recovery shell launched. Type 'exit' to continue boot",
        ])
        #expect(probe.hasSucceeded)
        #expect(!probe.hasFailed)
        #expect(probe.milestones.contains { $0.kind == .initramfsShell })
        #expect(!probe.milestones.contains { $0.kind == .userspaceReady })
    }

    @Test("A missing root device is reported distinctly from a panic")
    func rootMountFailure() {
        let probe = run([
            "[    0.000000] Linux version 6.6.0",
            "[    4.000000] VFS: Cannot open root device \"vda1\" or unknown-block(0,0)",
        ])
        #expect(probe.hasFailed)
        #expect(probe.milestones.contains { $0.kind == .rootMountFailure })
    }

    @Test("Each milestone is reported once, on first occurrence")
    func firstOccurrenceOnly() {
        var probe = GuestBootProbe()
        let line = "[    0.000000] Booting Linux on physical CPU 0x0000000000"
        #expect(probe.consume(line: line, elapsed: .seconds(1)) != nil)
        #expect(probe.consume(line: line, elapsed: .seconds(9)) == nil)
        #expect(probe.elapsed(for: .kernelStarted) == .seconds(1))
        #expect(probe.milestones.filter { $0.kind == .kernelStarted }.count == 1)
    }

    @Test("Unrelated console noise produces no milestones")
    func noiseIsIgnored() {
        let probe = run([
            "random daemon output",
            "[    0.100000] pci 0000:00:01.0: BAR 4: assigned",
            "usb 1-1: new high-speed USB device",
        ])
        #expect(probe.milestones.isEmpty)
        #expect(!probe.isFinished)
    }

    @Test("Terminal classification is exhaustive over all milestone kinds")
    func terminalClassification() {
        for kind in BootMilestone.Kind.allCases {
            // A kind can be a success, a failure, or intermediate — never both.
            #expect(!(kind.isTerminalSuccess && kind.isTerminalFailure))
        }
        #expect(BootMilestone.Kind.androidBootCompleted.isTerminalSuccess)
        #expect(BootMilestone.Kind.kernelPanic.isTerminalFailure)
        #expect(!BootMilestone.Kind.kernelStarted.isTerminalSuccess)
        #expect(!BootMilestone.Kind.kernelStarted.isTerminalFailure)
    }

    @Test("The timeline renders one line per milestone in order")
    func timelineRendering() {
        let probe = run([
            "[    0.000000] Booting Linux on physical CPU 0x0",
            "Welcome to Alpine Linux 3.20",
        ])
        let lines = probe.timeline().split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("kernelStarted"))
        #expect(lines[1].contains("userspaceReady"))
    }
}
