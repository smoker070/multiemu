import Foundation
import MultiemuBackend
import MultiemuSupport

/// Turns a `QEMUConfiguration` into an argument vector.
///
/// Pure and total: no file system access, no process spawning, no host probing.
/// That is what makes the QEMU command line — the part of an emulator most
/// likely to be quietly wrong — unit-testable without QEMU installed.
///
/// Arguments are passed to `Process` as an array, never through a shell, so no
/// quoting, word splitting or expansion occurs. Paths containing spaces are
/// therefore safe by construction.
public enum QEMUCommandBuilder {

    public static func arguments(for configuration: QEMUConfiguration) throws -> [String] {
        try validate(configuration)

        var arguments: [String] = []

        // --- Machine and accelerator ---
        //
        // The accelerator is passed as a separate `-accel` option rather than
        // folded into `-machine`, so that a failure to initialise HVF produces
        // a distinct, greppable QEMU error instead of a generic machine error.
        switch configuration.guestArchitecture {
        case .arm64:
            arguments += ["-machine", "virt"]
        case .x86_64:
            arguments += ["-machine", "q35"]
        }

        switch configuration.acceleration {
        case .hardwareVirtualization:
            arguments += ["-accel", "hvf"]
            // -cpu host is only meaningful — and only correct — when guest and
            // host architectures match, which is exactly when HVF is selected.
            arguments += ["-cpu", "host"]
        case .softwareTranslation:
            arguments += ["-accel", "tcg"]
            arguments += ["-cpu", "max"]
        }

        arguments += ["-smp", "\(configuration.vcpuCount)"]
        // QEMU's -m takes MiB by default. Converting here keeps the rest of the
        // code base in bytes, which is the unit every host API reports.
        arguments += ["-m", "\(configuration.memoryBytes / ByteCount.miB)"]

        // --- Direct kernel boot ---
        if let kernel = configuration.kernelURL {
            arguments += ["-kernel", kernel.path]
        }
        if let ramdisk = configuration.initialRamdiskURL {
            arguments += ["-initrd", ramdisk.path]
        }
        if !configuration.kernelCommandLine.isEmpty {
            arguments += ["-append", configuration.kernelCommandLine.joined(separator: " ")]
        }

        // --- Storage ---
        for drive in configuration.drives {
            arguments += [
                "-drive",
                "file=\(escapeOptionValue(drive.url.path)),if=none,id=\(drive.id),format=\(drive.format.rawValue),readonly=\(drive.readOnly ? "on" : "off"),node-name=\(drive.nodeName)",
            ]
            arguments += ["-device", "virtio-blk-pci,drive=\(drive.id)"]
        }

        // --- Networking ---
        //
        // User-mode networking (libslirp) is unprivileged and is the only
        // default. Port forwards bind 127.0.0.1 explicitly: an emulator
        // management or ADB port reachable from the local network is a
        // security defect, not a feature.
        if configuration.includeNetworkDevice {
            var netdev = "user,id=net0"
            for forward in configuration.portForwards {
                netdev += ",hostfwd=tcp:127.0.0.1:\(forward.hostPort)-:\(forward.guestPort)"
            }
            arguments += ["-netdev", netdev]
            arguments += ["-device", "virtio-net-pci,netdev=net0"]
        }

        // --- Entropy ---
        //
        // Without a virtio RNG the guest blocks on entropy during early boot,
        // which reads as a hang and costs seconds against the cold-boot target.
        arguments += ["-device", "virtio-rng-pci"]

        // --- Display ---
        //
        // QEMU never opens its own window: Multiemu owns presentation. The host
        // display backend is therefore `none` for headless work, or `dbus` when
        // an external process is to receive the scanouts. `cocoa` is never used.
        //
        // `-vga none` is emitted only for x86_64. The aarch64 `virt` machine has
        // no VGA adapter to suppress, and passing target-inapplicable options is
        // how a command line that works on one host fails on another.
        switch configuration.display {
        case .none, .virtioGPU:
            arguments += ["-display", "none"]
        case let .dbusDisplay(peerToPeer, _, _):
            arguments += ["-display", peerToPeer ? "dbus,p2p=on" : "dbus"]
        }

        if configuration.guestArchitecture == .x86_64 {
            arguments += ["-vga", "none"]
        }

        switch configuration.display {
        case .none:
            break
        case let .virtioGPU(width, height):
            arguments += ["-device", "virtio-gpu-pci,xres=\(width),yres=\(height)"]
        case let .dbusDisplay(_, width, height):
            arguments += ["-device", "virtio-gpu-pci,xres=\(width),yres=\(height)"]
        }

        // --- Audio ---
        //
        // USB audio on an xHCI controller, because it is the only audio device
        // this QEMU offers that this guest's kernel binds. The card refuses
        // rates below 48 kHz — `device only supports >= 48000Hz` — which is a
        // guest-side property and not something the command line can change.
        switch configuration.audio {
        case .none:
            break
        case .coreAudio, .wavFile, .dbus:
            let backend: String
            switch configuration.audio {
            case .coreAudio: backend = "coreaudio,id=snd0"
            case let .wavFile(path): backend = "wav,id=snd0,path=\(escapeOptionValue(path))"
            case .dbus: backend = "dbus,id=snd0"
            case .none: backend = ""
            }
            arguments += ["-audiodev", backend]
            arguments += ["-device", "qemu-xhci,id=xhci"]
            arguments += ["-device", "usb-audio,bus=xhci.0,audiodev=snd0"]
        }

        // --- Input ---
        if configuration.includeInputDevices {
            arguments += ["-device", "virtio-keyboard-pci"]
            arguments += ["-device", "virtio-tablet-pci"]
            // Input mappings turn keys and gamepad controls into touches, and
            // `org.qemu.Display1.MultiTouch` has nowhere to deliver them without
            // a multitouch device. Android expects one regardless.
            arguments += ["-device", "virtio-multitouch-pci"]
        }

        // --- virtio-console ports ---
        //
        // One virtio-serial bus carries them all; the guest names the ports
        // /dev/hvc0.. in attachment order, so the array index IS the guest's
        // number and the order here is part of the contract.
        if !configuration.consolePorts.isEmpty {
            arguments += [
                "-device",
                "virtio-serial-pci,id=vser0,max_ports=\(configuration.consolePorts.count + 1)",
            ]
            for (index, port) in configuration.consolePorts.enumerated() {
                let identifier = "hvc\(index)"
                switch port.backend {
                case .null:
                    arguments += ["-chardev", "null,id=\(identifier)"]
                case let .unixSocket(path):
                    arguments += [
                        "-chardev",
                        "socket,id=\(identifier),path=\(escapeOptionValue(path)),server=on,wait=off",
                    ]
                }
                arguments += [
                    "-device",
                    "virtconsole,bus=vser0.0,chardev=\(identifier)",
                ]
            }
        }

        // --- Shared folders ---
        for (index, folder) in configuration.sharedFolders.enumerated() {
            let identifier = "fsdev\(index)"
            // `mapped-xattr` keeps ownership metadata in extended attributes on
            // the host rather than letting the guest choose host uid/gid, and it
            // needs no privileges. `passthrough` would require them.
            var options = [
                "local",
                "id=\(identifier)",
                "path=\(escapeOptionValue(folder.hostDirectory.path))",
                "security_model=mapped-xattr",
            ]
            if folder.isReadOnly { options.append("readonly=on") }
            arguments += ["-fsdev", options.joined(separator: ",")]
            arguments += [
                "-device",
                "virtio-9p-pci,fsdev=\(identifier),mount_tag=\(folder.mountTag)",
            ]
        }

        // --- Serial console ---
        switch configuration.serial {
        case .stdio:
            arguments += ["-serial", "stdio"]
        case let .unixSocket(path):
            arguments += ["-serial", "unix:\(escapeOptionValue(path)),server=on,wait=off"]
        }

        // --- Control plane ---
        if let qmpSocketPath = configuration.qmpSocketPath {
            arguments += ["-qmp", "unix:\(escapeOptionValue(qmpSocketPath)),server=on,wait=off"]
        }

        if configuration.stopOnGuestReboot {
            arguments += ["-no-reboot"]
        }

        arguments += configuration.extraArguments
        return arguments
    }

    /// The full command line as a single copy-pasteable string.
    ///
    /// For logs and bug reports only — it is never executed through a shell.
    public static func displayCommandLine(for configuration: QEMUConfiguration) throws -> String {
        let arguments = try arguments(for: configuration)
        let quoted = arguments.map { argument -> String in
            argument.contains(where: { $0 == " " || $0 == "\t" }) ? "'\(argument)'" : argument
        }
        return ([configuration.executableURL.path] + quoted).joined(separator: " ")
    }

    static func validate(_ configuration: QEMUConfiguration) throws {
        guard configuration.vcpuCount >= 1 else {
            throw MultiemuError.invalidConfiguration(
                field: "vCPU count",
                detail: "At least one virtual CPU is required."
            )
        }
        guard configuration.memoryBytes >= 64 * ByteCount.miB else {
            throw MultiemuError.invalidConfiguration(
                field: "Guest memory",
                detail: "\(ByteCount.describe(configuration.memoryBytes)) is too small for any Linux guest."
            )
        }
        guard configuration.memoryBytes % ByteCount.miB == 0 else {
            throw MultiemuError.invalidConfiguration(
                field: "Guest memory",
                detail: "Must be a whole number of MiB; QEMU's -m option has MiB granularity."
            )
        }
        if configuration.initialRamdiskURL != nil && configuration.kernelURL == nil {
            throw MultiemuError.invalidConfiguration(
                field: "Initial ramdisk",
                detail: "An initrd was given without a kernel. Direct kernel boot requires both."
            )
        }
        if !configuration.kernelCommandLine.isEmpty && configuration.kernelURL == nil {
            throw MultiemuError.invalidConfiguration(
                field: "Kernel command line",
                detail: "A kernel command line was given without a kernel."
            )
        }
        for forward in configuration.portForwards {
            guard (1...65535).contains(forward.hostPort), (1...65535).contains(forward.guestPort) else {
                throw MultiemuError.invalidConfiguration(
                    field: "Port forward",
                    detail: "Ports must be between 1 and 65535; got \(forward.hostPort)->\(forward.guestPort)."
                )
            }
        }
        let driveIDs = configuration.drives.map(\.id)
        guard Set(driveIDs).count == driveIDs.count else {
            throw MultiemuError.invalidConfiguration(
                field: "Drives",
                detail: "Drive identifiers must be unique; got \(driveIDs.joined(separator: ", "))."
            )
        }
        let nodeNames = configuration.drives.map(\.nodeName)
        guard Set(nodeNames).count == nodeNames.count else {
            throw MultiemuError.invalidConfiguration(
                field: "Drives",
                detail: "Block node names must be unique; snapshots address nodes by name."
            )
        }
        // A UNIX socket path is capped by `sockaddr_un.sun_path`, and QEMU
        // refuses one that does not fit. Worth catching here: the paths are
        // generated from a support directory plus a device identifier, so this
        // fails on the user's machine and not on ours, and QEMU's own message
        // arrives only after everything else has been set up.
        for (index, port) in configuration.consolePorts.enumerated() {
            guard case let .unixSocket(path) = port.backend else { continue }
            guard path.utf8.count < Self.unixSocketPathLimit else {
                throw MultiemuError.invalidConfiguration(
                    field: "Console port \(index)",
                    detail: """
                        The socket path is \(path.utf8.count) bytes; a UNIX socket path must be \
                        under \(Self.unixSocketPathLimit). Use a shorter directory.
                        """
                )
            }
        }
    }

    /// `sizeof(sockaddr_un.sun_path)` on Darwin, including the terminator.
    ///
    /// Taken from the struct rather than written as 104, and shared with the
    /// control channel, so the command line and the client that connects to it
    /// can never disagree about what fits.
    static let unixSocketPathLimit = QMPClient.socketPathLimit

    /// Escapes a value for QEMU's comma-separated option syntax.
    ///
    /// QEMU splits an option string on commas and reads `,,` as a literal one.
    /// A user's directory may legitimately contain a comma — and without this
    /// the text after it would be parsed as a further option, which is both a
    /// bug and a way to inject settings through a folder name.
    static func escapeOptionValue(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: ",,")
    }
}
