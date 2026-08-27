import Foundation
import MultiemuBackend
import MultiemuSupport
import Testing
@testable import MultiemuQEMU

@Suite("QEMU command line")
struct QEMUCommandBuilderTests {

    private func configuration(
        architecture: GuestArchitecture = .arm64,
        acceleration: AccelerationMode = .hardwareVirtualization,
        memoryBytes: UInt64 = 2 * ByteCount.giB,
        vcpuCount: Int = 4,
        kernel: URL? = URL(fileURLWithPath: "/tmp/vmlinuz"),
        initrd: URL? = nil,
        append: [String] = [],
        drives: [QEMUConfiguration.Drive] = [],
        portForwards: [QEMUConfiguration.PortForward] = [],
        display: QEMUConfiguration.Display = .none,
        serial: QEMUConfiguration.Serial = .stdio,
        qmpSocketPath: String? = nil
    ) -> QEMUConfiguration {
        QEMUConfiguration(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/qemu-system-aarch64"),
            guestArchitecture: architecture,
            acceleration: acceleration,
            vcpuCount: vcpuCount,
            memoryBytes: memoryBytes,
            kernelURL: kernel,
            initialRamdiskURL: initrd,
            kernelCommandLine: append,
            drives: drives,
            portForwards: portForwards,
            display: display,
            serial: serial,
            qmpSocketPath: qmpSocketPath
        )
    }

    /// Asserts that `flag` is immediately followed by `value`.
    private func pair(_ arguments: [String], _ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: Machine and accelerator

    @Test("ARM64 with HVF uses -machine virt, -accel hvf, -cpu host")
    func arm64Hardware() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration())
        #expect(pair(arguments, "-machine") == "virt")
        #expect(pair(arguments, "-accel") == "hvf")
        #expect(pair(arguments, "-cpu") == "host")
    }

    @Test("x86_64 uses -machine q35")
    func x86Machine() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(architecture: .x86_64))
        #expect(pair(arguments, "-machine") == "q35")
    }

    @Test("Software translation uses -accel tcg and -cpu max, never -cpu host")
    func softwareTranslation() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(acceleration: .softwareTranslation))
        #expect(pair(arguments, "-accel") == "tcg")
        #expect(pair(arguments, "-cpu") == "max")
        // -cpu host under TCG would be wrong: there is no host CPU to expose.
        #expect(!arguments.contains("host"))
    }

    // MARK: Resources

    @Test("Memory is converted from bytes to MiB")
    func memoryConversion() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(memoryBytes: 4 * ByteCount.giB))
        #expect(pair(arguments, "-m") == "4096")
    }

    @Test("vCPU count is passed to -smp")
    func vcpuCount() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(vcpuCount: 6))
        #expect(pair(arguments, "-smp") == "6")
    }

    // MARK: Direct kernel boot

    @Test("Kernel, initrd and command line are wired for direct kernel boot")
    func directKernelBoot() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(
            kernel: URL(fileURLWithPath: "/images/vmlinuz"),
            initrd: URL(fileURLWithPath: "/images/initramfs"),
            append: ["console=ttyAMA0", "root=/dev/vda"]
        ))
        #expect(pair(arguments, "-kernel") == "/images/vmlinuz")
        #expect(pair(arguments, "-initrd") == "/images/initramfs")
        #expect(pair(arguments, "-append") == "console=ttyAMA0 root=/dev/vda")
    }

    // MARK: Storage

    @Test("Each drive produces a -drive and a matching virtio-blk device")
    func drives() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(drives: [
            .init(id: "system", url: URL(fileURLWithPath: "/images/system.img"), format: .raw, readOnly: true),
            .init(id: "userdata", url: URL(fileURLWithPath: "/devices/a/userdata.qcow2"), format: .qcow2, readOnly: false),
        ]))
        #expect(arguments.contains("file=/images/system.img,if=none,id=system,format=raw,readonly=on,node-name=system-node"))
        #expect(arguments.contains("file=/devices/a/userdata.qcow2,if=none,id=userdata,format=qcow2,readonly=off,node-name=userdata-node"))
        #expect(arguments.contains("virtio-blk-pci,drive=system"))
        #expect(arguments.contains("virtio-blk-pci,drive=userdata"))
    }

    @Test("Each drive gets a block node name distinct from its identifier")
    func driveNodeNames() throws {
        // QEMU keeps drive ids and block node names in one namespace, so
        // reusing the id fails with "Device name 'x' conflicts with an existing
        // node name" — a real failure found by running against QEMU.
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(drives: [
            .init(id: "disk0", url: URL(fileURLWithPath: "/a.qcow2"), format: .qcow2, readOnly: false),
        ]))
        let driveArgument = try #require(arguments.first { $0.contains("id=disk0") })
        #expect(driveArgument.contains("node-name=disk0-node"))
        #expect(!driveArgument.contains("node-name=disk0,"))
    }

    @Test("An explicit node name is honoured")
    func explicitNodeName() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(drives: [
            .init(id: "d", url: URL(fileURLWithPath: "/a.qcow2"), format: .qcow2,
                  readOnly: false, nodeName: "userdata"),
        ]))
        #expect(arguments.contains { $0.contains("node-name=userdata") })
    }

    @Test("Duplicate block node names are rejected, because snapshots address nodes by name")
    func duplicateNodeNames() {
        let broken = configuration(drives: [
            .init(id: "a", url: URL(fileURLWithPath: "/a"), format: .qcow2, readOnly: false, nodeName: "same"),
            .init(id: "b", url: URL(fileURLWithPath: "/b"), format: .qcow2, readOnly: false, nodeName: "same"),
        ])
        #expect(throws: MultiemuError.self) { try QEMUCommandBuilder.arguments(for: broken) }
    }

    @Test("Input devices are attached only when asked for")
    func inputDevices() throws {
        var withoutInput = configuration()
        withoutInput.includeInputDevices = false
        let bare = try QEMUCommandBuilder.arguments(for: withoutInput)
        #expect(!bare.contains("virtio-keyboard-pci"))

        var withInput = configuration()
        withInput.includeInputDevices = true
        let interactive = try QEMUCommandBuilder.arguments(for: withInput)
        #expect(interactive.contains("virtio-keyboard-pci"))
        // A tablet, not a mouse: absolute coordinates are what a touch-first
        // Android guest expects.
        #expect(interactive.contains("virtio-tablet-pci"))
        // Mapped input arrives as touches, so the guest needs a multitouch
        // device or `org.qemu.Display1.MultiTouch` has nowhere to deliver.
        #expect(interactive.contains("virtio-multitouch-pci"))
    }

    @Test("Duplicate drive identifiers are rejected")
    func duplicateDriveIDs() {
        let broken = configuration(drives: [
            .init(id: "same", url: URL(fileURLWithPath: "/a"), format: .raw, readOnly: true),
            .init(id: "same", url: URL(fileURLWithPath: "/b"), format: .raw, readOnly: true),
        ])
        #expect(throws: MultiemuError.self) { try QEMUCommandBuilder.arguments(for: broken) }
    }

    // MARK: Networking — security relevant

    @Test("Port forwards bind to 127.0.0.1 and never to a wildcard address")
    func portForwardsAreLoopbackOnly() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(portForwards: [
            .init(hostPort: 5555, guestPort: 5555),
            .init(hostPort: 8080, guestPort: 80),
        ]))
        let netdev = try #require(pair(arguments, "-netdev"))
        #expect(netdev.contains("hostfwd=tcp:127.0.0.1:5555-:5555"))
        #expect(netdev.contains("hostfwd=tcp:127.0.0.1:8080-:80"))
        // A forward without an explicit address binds all interfaces, which
        // would expose ADB to the local network.
        #expect(!netdev.contains("hostfwd=tcp::"))
        #expect(!netdev.contains("0.0.0.0"))
    }

    @Test("Networking can be disabled entirely")
    func networkingDisabled() throws {
        var withoutNetwork = configuration()
        withoutNetwork.includeNetworkDevice = false
        let arguments = try QEMUCommandBuilder.arguments(for: withoutNetwork)
        #expect(!arguments.contains("-netdev"))
    }

    @Test("Out-of-range ports are rejected")
    func invalidPorts() {
        let broken = configuration(portForwards: [.init(hostPort: 0, guestPort: 5555)])
        #expect(throws: MultiemuError.self) { try QEMUCommandBuilder.arguments(for: broken) }
    }

    // MARK: Display

    @Test("Headless configuration adds no graphics device")
    func headless() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(display: .none))
        #expect(pair(arguments, "-display") == "none")
        #expect(!arguments.contains { $0.contains("virtio-gpu") })
    }

    @Test("-vga is emitted only for x86_64, never for the aarch64 virt machine")
    func vgaIsX86Only() throws {
        // The aarch64 `virt` machine has no VGA adapter; passing a
        // target-inapplicable option is how a working command line breaks on
        // another host architecture.
        let arm = try QEMUCommandBuilder.arguments(for: configuration(architecture: .arm64))
        #expect(!arm.contains("-vga"))

        let intel = try QEMUCommandBuilder.arguments(for: configuration(architecture: .x86_64))
        #expect(pair(intel, "-vga") == "none")
    }

    @Test("Headless and 2D configurations use -display none")
    func displayIsNoneWhenHeadless() throws {
        for display: QEMUConfiguration.Display in [
            .none,
            .virtioGPU(widthInPixels: 1920, heightInPixels: 1080),
        ] {
            let arguments = try QEMUCommandBuilder.arguments(for: configuration(display: display))
            #expect(pair(arguments, "-display") == "none")
        }
    }

    @Test("virtio-gpu carries the requested scanout size")
    func virtioGPU() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(
            display: .virtioGPU(widthInPixels: 1920, heightInPixels: 1080)
        ))
        #expect(arguments.contains("virtio-gpu-pci,xres=1920,yres=1080"))
    }

    @Test("The D-Bus display backend defaults to peer-to-peer, which needs no session bus")
    func dbusDisplay() throws {
        // Milestone 2: plain `-display dbus` fails on macOS with
        // "Cannot spawn a message bus without a machine-id"; `p2p=on` starts.
        let p2p = try QEMUCommandBuilder.arguments(for: configuration(
            display: .dbusDisplay(peerToPeer: true, widthInPixels: 1920, heightInPixels: 1080)
        ))
        #expect(pair(p2p, "-display") == "dbus,p2p=on")
        #expect(p2p.contains("virtio-gpu-pci,xres=1920,yres=1080"))

        let bus = try QEMUCommandBuilder.arguments(for: configuration(
            display: .dbusDisplay(peerToPeer: false, widthInPixels: 1280, heightInPixels: 720)
        ))
        #expect(pair(bus, "-display") == "dbus")
    }

    @Test("QEMU's own Cocoa window is never requested")
    func neverCocoa() throws {
        for display: QEMUConfiguration.Display in [
            .none,
            .virtioGPU(widthInPixels: 1920, heightInPixels: 1080),
            .dbusDisplay(peerToPeer: true, widthInPixels: 1920, heightInPixels: 1080),
        ] {
            let arguments = try QEMUCommandBuilder.arguments(for: configuration(display: display))
            #expect(!arguments.contains("cocoa"))
        }
    }

    // MARK: Console and control plane

    @Test("Serial can be stdio or a UNIX socket")
    func serialModes() throws {
        #expect(pair(try QEMUCommandBuilder.arguments(for: configuration(serial: .stdio)), "-serial") == "stdio")
        let socket = try QEMUCommandBuilder.arguments(for: configuration(serial: .unixSocket(path: "/tmp/console.sock")))
        #expect(pair(socket, "-serial") == "unix:/tmp/console.sock,server=on,wait=off")
    }

    @Test("QMP socket is added only when requested, and never blocks startup")
    func qmpSocket() throws {
        #expect(!(try QEMUCommandBuilder.arguments(for: configuration()).contains("-qmp")))
        let withQMP = try QEMUCommandBuilder.arguments(for: configuration(qmpSocketPath: "/tmp/qmp.sock"))
        // wait=off matters: wait=on makes QEMU block until we connect, which
        // turns a supervisor bug into a silent hang.
        #expect(pair(withQMP, "-qmp") == "unix:/tmp/qmp.sock,server=on,wait=off")
    }

    @Test("A guest reboot stops the VM so a panic loop cannot hide")
    func noReboot() throws {
        #expect(try QEMUCommandBuilder.arguments(for: configuration()).contains("-no-reboot"))
    }

    @Test("A virtio RNG is always present so early boot does not block on entropy")
    func entropyDevice() throws {
        #expect(try QEMUCommandBuilder.arguments(for: configuration()).contains("virtio-rng-pci"))
    }

    // MARK: Argument safety

    @Test("Paths containing spaces stay a single argument and are never quoted")
    func pathsWithSpaces() throws {
        // The development tree itself lives under a path with spaces, so this
        // is a real case, not a hypothetical one.
        let spaced = URL(fileURLWithPath: "/Users/x/Ismoil Drive/000 Files/vmlinuz")
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(kernel: spaced))
        #expect(pair(arguments, "-kernel") == "/Users/x/Ismoil Drive/000 Files/vmlinuz")
        // No shell is involved, so no escaping must be applied to the argv entry.
        #expect(!arguments.contains { $0.contains("\\ ") })
    }

    @Test("The display command line quotes spaced arguments for humans only")
    func displayCommandLine() throws {
        let spaced = URL(fileURLWithPath: "/Users/x/Ismoil Drive/vmlinuz")
        let line = try QEMUCommandBuilder.displayCommandLine(for: configuration(kernel: spaced))
        #expect(line.contains("'/Users/x/Ismoil Drive/vmlinuz'"))
    }

    // MARK: Validation

    @Test("Zero vCPUs is rejected")
    func zeroCPUs() {
        #expect(throws: MultiemuError.self) {
            try QEMUCommandBuilder.arguments(for: configuration(vcpuCount: 0))
        }
    }

    @Test("Absurdly small memory is rejected")
    func tinyMemory() {
        #expect(throws: MultiemuError.self) {
            try QEMUCommandBuilder.arguments(for: configuration(memoryBytes: 8 * ByteCount.miB))
        }
    }

    @Test("Memory that is not a whole number of MiB is rejected")
    func nonWholeMiBMemory() {
        #expect(throws: MultiemuError.self) {
            try QEMUCommandBuilder.arguments(for: configuration(memoryBytes: 2 * ByteCount.giB + 1))
        }
    }

    @Test("An initrd without a kernel is rejected")
    func initrdWithoutKernel() {
        #expect(throws: MultiemuError.self) {
            try QEMUCommandBuilder.arguments(for: configuration(
                kernel: nil,
                initrd: URL(fileURLWithPath: "/images/initramfs")
            ))
        }
    }

    @Test("A kernel command line without a kernel is rejected")
    func appendWithoutKernel() {
        #expect(throws: MultiemuError.self) {
            try QEMUCommandBuilder.arguments(for: configuration(kernel: nil, append: ["quiet"]))
        }
    }

    @Test("Executable name follows the guest architecture")
    func executableNames() {
        #expect(QEMUConfiguration.executableName(for: .arm64) == "qemu-system-aarch64")
        #expect(QEMUConfiguration.executableName(for: .x86_64) == "qemu-system-x86_64")
    }
}

@Suite("Shared folder arguments")
struct SharedFolderArgumentTests {

    /// A configuration with nothing in it but the essentials, so a test can
    /// see only what the share adds.
    private func baseConfiguration() throws -> QEMUConfiguration {
        try QEMUConfiguration(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/qemu-system-aarch64"),
            guestArchitecture: .arm64,
            acceleration: .hardwareVirtualization,
            vcpuCount: 2,
            memoryBytes: 2 * ByteCount.giB,
            kernelURL: URL(fileURLWithPath: "/tmp/vmlinuz")
        )
    }



    @Test("A comma in a disk path cannot inject a further QEMU option")
    func drivePathCommaIsEscaped() throws {
        var configuration = try baseConfiguration()
        // A device folder named for a phone is exactly how this reaches a user:
        // QEMU splits `-drive file=...` on the comma and opens the wrong path.
        configuration.drives = [.init(
            id: "disk0",
            url: URL(fileURLWithPath: "/Users/x/Pixel 6, API 37/userdata.img"),
            format: .qcow2, readOnly: false)]
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)
        #expect(arguments.contains { $0.hasPrefix("file=/Users/x/Pixel 6,, API 37/userdata.img,if=none") })
    }

    @Test("A comma in the control socket path is escaped for -qmp and -serial")
    func controlSocketCommaIsEscaped() throws {
        var configuration = try baseConfiguration()
        configuration.qmpSocketPath = "/tmp/a,b/qmp.sock"
        configuration.serial = .unixSocket(path: "/tmp/a,b/console.sock")
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)
        #expect(arguments.contains("unix:/tmp/a,,b/qmp.sock,server=on,wait=off"))
        #expect(arguments.contains("unix:/tmp/a,,b/console.sock,server=on,wait=off"))
    }

    // MARK: virtio-console ports

    @Test("No console ports means no virtio-serial bus at all")
    func noConsolePortsAddsNothing() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: baseConfiguration())
        #expect(!arguments.contains { $0.contains("virtio-serial") })
        #expect(!arguments.contains { $0.contains("virtconsole") })
    }

    @Test("Console ports attach to one bus, in order, so index N is the guest's hvcN")
    func consolePortsAttachInOrder() throws {
        var configuration = try baseConfiguration()
        configuration.consolePorts = QEMUConfiguration.ConsolePort.silentBank(count: 3)
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)

        #expect(arguments.contains { $0.hasPrefix("virtio-serial-pci,id=vser0") })
        // The guest numbers ports by attachment order, so the order the
        // arguments appear in IS the mapping to /dev/hvcN.
        let devices = arguments.filter { $0.hasPrefix("virtconsole") }
        #expect(devices == [
            "virtconsole,bus=vser0.0,chardev=hvc0",
            "virtconsole,bus=vser0.0,chardev=hvc1",
            "virtconsole,bus=vser0.0,chardev=hvc2",
        ])
        #expect(arguments.filter { $0.hasPrefix("null,id=hvc") }.count == 3)
    }

    @Test("The bus is sized to hold every port")
    func busIsLargeEnough() throws {
        var configuration = try baseConfiguration()
        configuration.consolePorts = QEMUConfiguration.ConsolePort.silentBank(count: 20)
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)
        // One more than the ports: virtio-serial reserves a control port.
        #expect(arguments.contains("virtio-serial-pci,id=vser0,max_ports=21"))
        #expect(arguments.filter { $0.hasPrefix("virtconsole") }.count == 20)
    }

    @Test("A socket-backed port listens, and does not block startup waiting for a peer")
    func socketBackedPortListensWithoutWaiting() throws {
        var configuration = try baseConfiguration()
        configuration.consolePorts = [
            .init(backend: .null),
            .init(backend: .unixSocket(path: "/tmp/mmu/hvc1.sock")),
        ]
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)
        // `wait=off` matters: with it on, QEMU would not run until something
        // connected, so a responder could never be started afterwards.
        #expect(arguments.contains("socket,id=hvc1,path=/tmp/mmu/hvc1.sock,server=on,wait=off"))
        #expect(arguments.contains("null,id=hvc0"))
    }

    @Test("A comma in a socket path cannot inject a further QEMU option")
    func socketPathCommaIsEscaped() throws {
        var configuration = try baseConfiguration()
        configuration.consolePorts = [.init(backend: .unixSocket(path: "/tmp/od,d/hvc.sock"))]
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)
        #expect(arguments.contains("socket,id=hvc0,path=/tmp/od,,d/hvc.sock,server=on,wait=off"))
    }

    @Test("A socket path too long for sockaddr_un is refused here, not by QEMU later")
    func overlongSocketPathIsRefused() throws {
        var configuration = try baseConfiguration()
        let tooLong = "/tmp/" + String(repeating: "d", count: 120) + "/hvc.sock"
        configuration.consolePorts = [.init(backend: .unixSocket(path: tooLong))]
        #expect(throws: MultiemuError.self) {
            _ = try QEMUCommandBuilder.arguments(for: configuration)
        }
    }

    @Test("A path just under the limit is accepted")
    func socketPathAtLimitIsAccepted() throws {
        var configuration = try baseConfiguration()
        let path = "/" + String(repeating: "d", count: 102)
        #expect(path.utf8.count == 103)
        configuration.consolePorts = [.init(backend: .unixSocket(path: path))]
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)
        #expect(arguments.contains("socket,id=hvc0,path=\(path),server=on,wait=off"))
    }

    private func makeShare(named name: String, readOnly: Bool = true) throws -> SharedFolder {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try SharedFolder(hostDirectory: root, mountTag: "share", isReadOnly: readOnly)
    }

    @Test("A read-only share is exported read-only")
    func readOnlyShareIsExportedReadOnly() throws {
        let share = try makeShare(named: "multiemu-args-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: share.hostDirectory) }

        var configuration = try baseConfiguration()
        configuration.sharedFolders = [share]
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)

        let fsdev = try #require(arguments.first { $0.hasPrefix("local,") })
        #expect(fsdev.contains("readonly=on"))
        // Ownership metadata stays on the host side rather than being chosen by
        // the guest, and this model needs no privileges.
        #expect(fsdev.contains("security_model=mapped-xattr"))
        #expect(arguments.contains { $0.contains("virtio-9p-pci") && $0.contains("mount_tag=share") })
    }

    @Test("A writable share omits the read-only flag")
    func writableShareIsWritable() throws {
        let share = try makeShare(named: "multiemu-args-\(UUID().uuidString)", readOnly: false)
        defer { try? FileManager.default.removeItem(at: share.hostDirectory) }

        var configuration = try baseConfiguration()
        configuration.sharedFolders = [share]
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)
        let fsdev = try #require(arguments.first { $0.hasPrefix("local,") })
        #expect(!fsdev.contains("readonly=on"))
    }

    @Test("A comma in a folder name is escaped, not parsed as another option")
    func commasAreEscaped() throws {
        // QEMU splits these options on commas. Without escaping, everything
        // after a comma in the user's own folder name would be read as further
        // settings — a bug, and a way to inject options through a directory name.
        let share = try makeShare(named: "multiemu,args-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: share.hostDirectory) }

        var configuration = try baseConfiguration()
        configuration.sharedFolders = [share]
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)
        let fsdev = try #require(arguments.first { $0.hasPrefix("local,") })

        #expect(fsdev.contains(",,"))
        // The escaped form must still round-trip to the real path.
        let pathOption = try #require(
            fsdev.components(separatedBy: ",security_model").first?
                .components(separatedBy: "path=").last)
        #expect(pathOption.replacingOccurrences(of: ",,", with: ",") == share.hostDirectory.path)
    }

    @Test("No share means no 9p device at all")
    func noShareMeansNoDevice() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: baseConfiguration())
        #expect(!arguments.contains { $0.contains("virtio-9p") })
        #expect(!arguments.contains { $0.hasPrefix("local,") })
    }
}

@Suite("Audio devices on the command line")
struct QEMUAudioBuilderTests {

    private func configuration(audio: QEMUConfiguration.Audio) -> QEMUConfiguration {
        QEMUConfiguration(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/qemu-system-aarch64"),
            guestArchitecture: .arm64,
            acceleration: .hardwareVirtualization,
            vcpuCount: 2,
            memoryBytes: 2 * 1024 * 1024 * 1024,
            audio: audio)
    }

    @Test("No audio means no audio device at all")
    func noneEmitsNothing() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(audio: .none))
        #expect(!arguments.contains("-audiodev"))
        #expect(!arguments.contains { $0.contains("usb-audio") })
    }

    @Test("Audio is USB audio on an xHCI controller, because it is the only one that works")
    func usesUSBAudio() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(audio: .coreAudio))
        // Measured, not chosen: attaching intel-hda, AC97 and usb-audio at once
        // and asking the guest what it enumerated produced exactly one card,
        // the USB one. A device the guest does not bind is silence with extra
        // steps.
        #expect(arguments.contains("qemu-xhci,id=xhci"))
        #expect(arguments.contains("usb-audio,bus=xhci.0,audiodev=snd0"))
        #expect(arguments.contains("coreaudio,id=snd0"))
        // The controller must precede the device that sits on its bus.
        let controller = try #require(arguments.firstIndex(of: "qemu-xhci,id=xhci"))
        let device = try #require(arguments.firstIndex(of: "usb-audio,bus=xhci.0,audiodev=snd0"))
        #expect(controller < device)
    }

    @Test("A capture path is escaped, so a comma in it cannot become another option")
    func wavPathIsEscaped() throws {
        // QEMU splits options on commas. An unescaped path containing one would
        // have the rest parsed as further settings — the same trap that shows
        // up in `-drive file=` and in shared-folder paths.
        let arguments = try QEMUCommandBuilder.arguments(
            for: configuration(audio: .wavFile(path: "/tmp/take 1, final.wav")))
        let backend = try #require(arguments.first { $0.hasPrefix("wav,") })
        #expect(backend.contains("take 1,, final.wav"))
    }

    @Test("The D-Bus backend pairs with the display channel")
    func dbusBackend() throws {
        let arguments = try QEMUCommandBuilder.arguments(for: configuration(audio: .dbus))
        #expect(arguments.contains("dbus,id=snd0"))
    }
}

@Suite("Backend audio choice becomes a QEMU device")
struct QEMUAudioMappingTests {

    @Test("Disabled means no device; host output means a CoreAudio-backed card")
    func mapsBothCases() {
        #expect(QEMUConfiguration.audio(for: .disabled) == .none)
        // Not the D-Bus backend: nothing in this project implements a client
        // for `org.qemu.Display1.Audio`, so picking it would look wired and be
        // silent.
        #expect(QEMUConfiguration.audio(for: .hostOutput) == .coreAudio)
    }

    @Test("A request with audio produces a sound device on the command line")
    func reachesTheCommandLine() throws {
        // The end-to-end shape of the plumbing, without starting a guest: the
        // backend-level choice has to survive all the way to an argument.
        let configuration = QEMUConfiguration(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/qemu-system-aarch64"),
            guestArchitecture: .arm64,
            acceleration: .hardwareVirtualization,
            vcpuCount: 2,
            memoryBytes: 2 * 1024 * 1024 * 1024,
            audio: QEMUConfiguration.audio(for: .hostOutput))
        let arguments = try QEMUCommandBuilder.arguments(for: configuration)
        #expect(arguments.contains("usb-audio,bus=xhci.0,audiodev=snd0"))
    }
}
