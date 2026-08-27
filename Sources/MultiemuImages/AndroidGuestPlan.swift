import Foundation
import MultiemuBackend
import MultiemuDisks
import MultiemuSupport

/// Where one device's private, writable disks live.
///
/// Everything in the image store is SHARED between devices and must stay
/// read-only — a single writable opener locks every other device out of that
/// file (docs/VERIFY.md, `QEMU-SHARES-READ-ONLY-IMAGES`). Anything a device
/// writes therefore goes here instead, as a copy-on-write overlay rather than a
/// copy of the image.
public struct DevicePrivateStorage: Sendable {
    public var directory: URL
    public var disks: VirtualDiskManager

    public init(directory: URL, disks: VirtualDiskManager) {
        self.directory = directory
        self.disks = disks
    }

    func overlayURL(named name: String) -> URL {
        directory.appendingPathComponent("\(name).qcow2")
    }
}

/// Turns an installed image set into something the backend can start.
///
/// Kept separate from `ImageStore` because it encodes *boot policy* — which
/// kernel arguments an Android guest needs and in what order partitions are
/// attached — rather than storage mechanics.
public struct AndroidGuestPlan: Sendable {

    /// How partitions are presented to the guest.
    ///
    /// Android locates partitions through `/dev/block/by-name/` symlinks that
    /// ueventd creates from the device tree or from `androidboot.boot_devices`.
    /// Which of these layouts an image needs is a property of the image, not of
    /// the host, and is determined empirically per image set.
    public enum PartitionLayout: String, Codable, Sendable {
        /// One virtio-blk device per partition, in manifest order. Simple, and
        /// sufficient for images that accept partitions as separate devices.
        case separateBlockDevices
        /// A single disk carrying GPT partitions with Android's expected names.
        /// This is what Cuttlefish-style images assume, and building one is a
        /// separate piece of work — see docs/VERIFY.md → `ANDROID-PARTITION-LAYOUT`.
        case compositeGPTDisk
    }

    /// Kernel arguments Multiemu always supplies for an Android guest.
    ///
    /// Deliberately minimal. Everything image-specific comes from the manifest
    /// or from the image's own boot/vendor_boot command lines, because guessing
    /// `androidboot.*` values produces guests that boot into a state no one can
    /// explain.
    public static let baseKernelArguments = [
        // PL011 UART on the aarch64 `virt` machine. Without a console, a
        // stalled boot is indistinguishable from a failed one.
        "console=ttyAMA0",
        // Keep kernel messages on the console after userspace starts, so first
        // stage init failures are visible.
        "printk.devkmsg=on",
    ]

    /// Arguments that describe **this emulator's machine**, not the image.
    ///
    /// They belong here and not in an image manifest because every one of them
    /// is a fact about how Multiemu builds the guest, and would be wrong for
    /// the same image on another host:
    ///
    /// * `androidboot.console=hvc1` must match `shellConsolePort` above.
    /// * `boot_devices` is the aarch64 `virt` machine's PCIe address.
    /// * `verifiedbootstate=orange` is true because the composite builder
    ///   relaxes AVB; an image signed for a real device would not need it.
    /// * `slot_suffix=_a` is the slot the composite disk is built with.
    /// * `vsock_lights_port` is a workaround for a HAL that binds vsock port 0
    ///   and is refused; any port above 1023 will do.
    ///
    /// The kernel arguments alongside them are ordinary Android boot settings
    /// that no image chooses either.
    public static let machineKernelArguments = [
        "init=/init",
        "panic=-1",
        "cma=0",
        "loop.max_part=7",
        // Audit spam outruns auditd on this guest and pushes services toward
        // watchdog timeouts; it took time-to-311-services from ~200 s to 16 s.
        "audit=0",
        "androidboot.slot_suffix=_a",
        "androidboot.force_normal_boot=1",
        "androidboot.boot_devices=4010000000.pcie",
        "androidboot.verifiedbootstate=orange",
        "androidboot.vsock_lights_port=6800",
        "androidboot.console=hvc\(shellConsolePort)",
        "androidboot.lcd_density=320",
    ]

    /// Arguments added only while bringing a new image up.
    ///
    /// `selinux=permissive` in particular must never reach a shipping default:
    /// it disables an Android security boundary. It exists so that a first boot
    /// fails for interesting reasons rather than on policy denials.
    public static let bringUpKernelArguments = [
        "androidboot.selinux=permissive",
        "androidboot.first_stage_console=1",
    ]

    /// virtio-console ports an Android guest expects, and what answers them.
    ///
    /// Milestone 4 established all three numbers against a running guest, and
    /// they are not adjustable taste:
    ///
    /// * **20 ports.** Cuttlefish HALs open `/dev/hvc0` upward and fail on
    ///   `ENOENT`. uwb wants hvc9, oemlock hvc10, sensors hvc18.
    /// * **Sensors on 18.** The sensors multihal speaks the goldfish `qemud`
    ///   protocol there and will not register `ISensors` until something
    ///   answers. A HAL blocked in `read()` holds `system_server` for the whole
    ///   boot — worse than a missing port, because nothing reports it.
    /// * **A shell on 1**, matching `androidboot.console=hvc1`. That is the
    ///   channel `GuestServiceQuiesce` and ADB enablement use.
    ///
    /// Without these the guest stalls in second-stage init until the boot
    /// timeout, which is exactly what the application did before this existed:
    /// `Guest console ports — none configured; an Android guest stalls without
    /// the ports its HALs expect.`
    public static let consolePortCount = 20
    public static let sensorsConsolePort = 18
    public static let shellConsolePort = 1

    public var manifest: ImageManifest
    public var store: ImageStore
    public var layout: PartitionLayout
    /// Enables `bringUpKernelArguments`. Off by default.
    public var bringUpMode: Bool
    /// Size of the `userdata` partition when the composite layout creates it.
    public var userdataSizeBytes: UInt64
    /// A/B slot suffix for the composite layout.
    public var slotSuffix: String
    /// This device's private writable storage. Required to start: without it
    /// two devices on one image would open the same writable file.
    public var privateStorage: DevicePrivateStorage?
    /// Relax Android Verified Boot in the composite disk.
    ///
    /// Every image this project can obtain is signed with keys it does not
    /// hold, and `fs_mgr` refuses to mount partitions it cannot verify — so
    /// without this an AOSP image stops at "Found unknown public key used to
    /// sign /system". Off by default because it turns off a security check;
    /// see `AndroidVerifiedBoot` for what is given up.
    public var relaxesVerifiedBoot: Bool

    public init(
        manifest: ImageManifest,
        store: ImageStore,
        layout: PartitionLayout? = nil,
        bringUpMode: Bool = false,
        userdataSizeBytes: UInt64 = 32 * ByteCount.giB,
        slotSuffix: String = AndroidCompositeLayout.defaultSlotSuffix,
        privateStorage: DevicePrivateStorage? = nil,
        relaxesVerifiedBoot: Bool = false
    ) {
        self.privateStorage = privateStorage
        self.relaxesVerifiedBoot = relaxesVerifiedBoot
        self.manifest = manifest
        self.store = store
        // The image's own answer wins; the argument is an override for a
        // caller experimenting with a layout the image did not declare.
        self.layout = layout ?? manifest.partitionLayout ?? .separateBlockDevices
        self.bringUpMode = bringUpMode
        self.userdataSizeBytes = userdataSizeBytes
        self.slotSuffix = slotSuffix
    }

    /// Where the composite disk for this image lives.
    public var compositeDiskURL: URL {
        // Keyed by what actually goes INTO the disk, not just by the image.
        //
        // The layout depends on the userdata size and the A/B slot, both of
        // which are per device. One shared `composite.img` meant a device
        // configured for 64 GiB could silently adopt a 32 GiB disk built for
        // another — the file exists, so it is reused, and nothing reports a
        // mismatch.
        //
        // Verified boot is part of the key for the same reason, and a stronger
        // one: a disk whose partitions are unverified must never be picked up
        // by a device that did not ask for that.
        let sizeGiB = userdataSizeBytes / ByteCount.giB
        let verification = relaxesVerifiedBoot ? "-avbrelaxed" : ""
        let name = "composite-\(slotSuffix.isEmpty ? "noslot" : slotSuffix)-\(sizeGiB)g\(verification).img"
        return store.directory(for: manifest.imageIdentifier)
            .appendingPathComponent("derived", isDirectory: true)
            .appendingPathComponent(name)
    }

    /// Builds the composite disk if it is missing.
    ///
    /// Rebuilt only when absent: the disk contains `userdata`, so regenerating
    /// it on every start would silently factory-reset the device.
    @discardableResult
    public func ensureCompositeDisk(
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> CompositeDiskBuilder.Layout {
        let url = compositeDiskURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let partitions = AndroidCompositeLayout.partitions(
            manifest: manifest, store: store, slotSuffix: slotSuffix,
            userdataSizeBytes: userdataSizeBytes
        )
        if FileManager.default.fileExists(atPath: url.path) {
            progress?("composite disk already present; reusing it so userdata survives")
            return CompositeDiskBuilder.Layout(
                diskURL: url,
                totalSizeBytes: UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                partitions: try CompositeDiskBuilder().plan(partitions)
            )
        }

        // Build somewhere private, then publish atomically.
        //
        // The existence check above races: building takes minutes and writes
        // the file at the START, so a second device starting meanwhile would
        // find a partially written disk, decide it was "already present", and
        // boot from a truncated image. `link` fails with EEXIST rather than
        // overwriting, so whichever device finishes first wins and the other
        // adopts its result — no lock file to go stale if a build is killed.
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent("composite-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }

        var builder = CompositeDiskBuilder()
        builder.relaxesVerifiedBoot = relaxesVerifiedBoot
        let layout = try builder.build(
            partitions: partitions, to: staging,
            diskGUIDSeed: manifest.imageIdentifier, progress: progress
        )

        do {
            try FileManager.default.linkItem(at: staging, to: url)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else { throw error }
            progress?("another device published the composite disk first; using theirs")
        }
        return CompositeDiskBuilder.Layout(
            diskURL: url, totalSizeBytes: layout.totalSizeBytes, partitions: layout.partitions)
    }

    /// Composes the kernel command line.
    ///
    /// Order matters: later arguments win for repeated keys, so image-supplied
    /// values override Multiemu's generic ones, and explicit bring-up flags
    /// override both.
    public func kernelCommandLine(unpack: ImageStore.UnpackResult?) -> [String] {
        var arguments = Self.baseKernelArguments + Self.machineKernelArguments

        if let unpack {
            arguments += unpack.vendorBootCommandLine?.split(separator: " ").map(String.init) ?? []
            arguments += unpack.bootImageCommandLine.split(separator: " ").map(String.init)
        }
        arguments += manifest.requiredKernelArguments
        if bringUpMode { arguments += Self.bringUpKernelArguments }

        // De-duplicate by key, keeping the last occurrence.
        var seenKeys: [String: Int] = [:]
        var result: [String] = []
        for argument in arguments where !argument.isEmpty {
            let key = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if let existing = seenKeys[key] {
                result[existing] = argument
            } else {
                seenKeys[key] = result.count
                result.append(argument)
            }
        }
        return result
    }

    /// Partitions in the order they are attached, read-only first so that
    /// device naming stays stable when a device's writable images are recreated.
    public func attachedPartitions() -> (readOnly: [URL], writable: [URL]) {
        let readOnly = manifest.files
            .filter { $0.role.isReadOnly }
            .sorted { $0.role.rawValue < $1.role.rawValue }
            .map { store.url(of: $0, in: manifest.imageIdentifier) }
        let writable = manifest.files
            .filter { $0.role.isWritable }
            .sorted { $0.role.rawValue < $1.role.rawValue }
            .map { store.url(of: $0, in: manifest.imageIdentifier) }
        return (readOnly, writable)
    }

    /// Builds the start request.
    ///
    /// Verifies image integrity first: nothing boots unverified, and a corrupt
    /// image must fail as a corrupt image rather than as a mystery boot hang.
    public func makeStartRequest(
        resources: GuestResourceRequest,
        acceleration: AccelerationMode,
        adbHostPort: Int? = nil,
        audio: GuestAudioMode = .disabled,
        bootTimeout: Duration = .seconds(180)
    ) throws -> GuestStartRequest {
        let report = try store.verify(manifest.imageIdentifier)
        guard report.isIntact else {
            throw MultiemuError.invalidConfiguration(
                field: "Guest image",
                detail: report.problems.joined(separator: " ")
            )
        }

        let unpack = try store.unpackBootImages(for: manifest.imageIdentifier)

        guard let privateStorage else {
            throw MultiemuError.invalidConfiguration(
                field: "Device storage",
                detail: """
                    This device has no private storage. Images in the store are shared \
                    between devices and are opened read-only, so a device's writable \
                    partitions must live in its own directory.
                    """
            )
        }

        let disks: [GuestDiskImage]
        switch layout {
        case .separateBlockDevices:
            let partitions = attachedPartitions()
            // Read-only partitions are attached from the shared store directly:
            // several devices opening one file read-only is exactly the case
            // QEMU permits, and it is what "shared, not copied" means here.
            let shared = partitions.readOnly.map {
                GuestDiskImage(url: $0, format: .raw, isReadOnly: true)
            }
            // Writable partitions become per-device overlays over the store's
            // copy, so each device gets its own /data without duplicating the
            // image and without any two devices contending for one file.
            let private_ = try partitions.writable.map { source -> GuestDiskImage in
                let overlay = try privateStorage.ensureOverlay(over: source)
                return GuestDiskImage(url: overlay, format: .qcow2, isReadOnly: false)
            }
            disks = shared + private_
        case .compositeGPTDisk:
            // The composite carries userdata inside it, so it cannot be attached
            // writable while shared. It is built once per image set, stays
            // read-only forever after, and each device writes into its own
            // overlay above it.
            let base = try ensureCompositeDisk()
            let overlay = try privateStorage.ensureOverlay(over: base.diskURL, named: "composite")
            disks = [GuestDiskImage(url: overlay, format: .qcow2, isReadOnly: false)]
        }

        return GuestStartRequest(
            guestArchitecture: manifest.guestArchitecture,
            acceleration: acceleration,
            resources: resources,
            kernelURL: unpack.kernelURL,
            initialRamdiskURL: unpack.ramdiskURL,
            kernelCommandLine: kernelCommandLine(unpack: unpack),
            disks: disks,
            adbHostPort: adbHostPort,
            audio: audio,
            consolePorts: try GuestConsolePort.bank(
                count: Self.consolePortCount,
                services: [
                    Self.sensorsConsolePort: .sensors,
                    Self.shellConsolePort: .androidConsole,
                ]),
            // Android first boot legitimately takes minutes: dex2oat and initial
            // property generation dominate. The 45 s product target applies to
            // cold boot of an already-initialised device, not to this.
            bootTimeout: bootTimeout
        )
    }
}

extension DevicePrivateStorage {

    /// Returns this device's overlay over a shared image, creating it if absent.
    ///
    /// The overlay is named after the source so several partitions can be
    /// overlaid into one device directory without colliding — with an
    /// `-overlay` suffix, which is not decoration.
    ///
    /// `VirtualDeviceStore.create` eagerly makes a blank `userdata.qcow2` for
    /// the generic path, where a device owns its disk outright. An Android
    /// image supplies its own `userdata.img` and wants an overlay *over* it.
    /// Both wanted the name `userdata.qcow2`, creation won because it runs
    /// first, and starting the device then failed:
    ///
    ///     An overlay already exists here but is backed by nothing rather than
    ///     …/userdata.img. Remove it, or use a different path; adopting it
    ///     would boot the wrong disk.
    ///
    /// That guard was right — the two files mean different things. The suffix
    /// is how they stop sharing a name. The composite branch already avoided
    /// the collision by passing an explicit name; this is the same fix for the
    /// per-partition branch.
    func ensureOverlay(over source: URL, named name: String? = nil) throws -> URL {
        let stem = name ?? "\(source.deletingPathExtension().lastPathComponent)-overlay"
        let overlay = overlayURL(named: stem)
        try disks.ensureOverlay(at: overlay, backedBy: source, baseFormat: .raw)
        return overlay
    }
}
