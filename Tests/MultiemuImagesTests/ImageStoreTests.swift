import Foundation
import MultiemuBackend
import MultiemuDisks
import MultiemuSupport
import Testing
@testable import MultiemuImages

/// Builds a small but structurally real installed image set on disk.
let diskToolAvailable = VirtualDiskManager.locateDevelopmentTool() != nil

struct TemporaryImageSet {
    let root: URL
    let store: ImageStore
    let identifier = "test-image"
    let kernel = SyntheticBootImage.filler(0xA1, count: 8192)
    let genericRamdisk = SyntheticBootImage.filler(0xB2, count: 4096)
    let vendorRamdisk = SyntheticBootImage.filler(0xC3, count: 2048)

    /// A device's own writable area, separate from the shared image store.
    func privateStorage(device: String = "device-a") throws -> DevicePrivateStorage {
        let disks = try #require(VirtualDiskManager.locateDevelopmentTool())
        let directory = root.appendingPathComponent(device, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return DevicePrivateStorage(directory: directory, disks: disks)
    }

    init(androidAPILevel: Int = 34, includeVendorBoot: Bool = true) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-images-\(UUID().uuidString)", isDirectory: true)
        store = ImageStore(root: root)

        let directory = store.directory(for: identifier)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var files: [ManifestFile] = []

        func write(_ data: Data, name: String, role: PartitionRole) throws {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            files.append(.init(
                role: role,
                relativePath: name,
                sizeBytes: UInt64(data.count),
                sha256: try ImageStore.sha256(ofFileAt: url)
            ))
        }

        try write(
            SyntheticBootImage.bootImage(
                headerVersion: 4, kernel: kernel, ramdisk: genericRamdisk,
                commandLine: "androidboot.hardware=multiemu"
            ),
            name: "boot.img", role: .bootImage
        )
        if includeVendorBoot {
            try write(
                SyntheticBootImage.vendorBootImage(
                    headerVersion: 4, vendorRamdisk: vendorRamdisk,
                    commandLine: "androidboot.boot_devices=a003e00.virtio_mmio"
                ),
                name: "vendor_boot.img", role: .vendorBootImage
            )
        }
        try write(SyntheticBootImage.filler(0xD4, count: 1024), name: "system.img", role: .system)
        try write(SyntheticBootImage.filler(0xE5, count: 512), name: "userdata.img", role: .userdata)

        let manifest = ImageManifest(
            imageIdentifier: identifier,
            displayName: "Test Android",
            androidRelease: "14",
            androidAPILevel: androidAPILevel,
            guestArchitecture: .arm64,
            source: "synthesised by MultiemuImagesTests",
            licenseNotice: "test fixture; not redistributable",
            requiredKernelArguments: ["androidboot.hardware=multiemu"],
            files: files
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: store.manifestURL(for: identifier))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Image manifest")
struct ImageManifestTests {

    private func manifest(apiLevel: Int = 34, source: String = "test", license: String = "test",
                          files: [ManifestFile] = [.init(role: .bootImage, relativePath: "boot.img", sizeBytes: 1, sha256: "x")]
    ) -> ImageManifest {
        ImageManifest(
            imageIdentifier: "id", displayName: "d", androidRelease: "14",
            androidAPILevel: apiLevel, guestArchitecture: .arm64,
            source: source, licenseNotice: license, files: files
        )
    }

    @Test("A manifest round-trips through JSON")
    func roundTrip() throws {
        let original = manifest()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ImageManifest.self, from: data) == original)
    }

    @Test("Android 9 is the floor; earlier releases are rejected")
    func androidVersionFloor() {
        #expect(manifest(apiLevel: 28).meetsMinimumAndroidVersion)
        #expect(!manifest(apiLevel: 27).meetsMinimumAndroidVersion)
        #expect(manifest(apiLevel: 27).structuralProblems().contains { $0.contains("API level 27") })
    }

    @Test("Provenance and redistribution status are required, not optional documentation")
    func provenanceRequired() {
        #expect(manifest(source: "  ").structuralProblems().contains { $0.contains("where the image came from") })
        #expect(manifest(license: "").structuralProblems().contains { $0.contains("redistribution status") })
    }

    @Test("An image set with no kernel and no boot image is rejected")
    func kernelRequired() {
        #expect(manifest(files: []).structuralProblems().contains { $0.contains("neither a boot image nor") })
    }

    @Test("Two files claiming the same partition role are rejected")
    func duplicateRoles() {
        let problems = manifest(files: [
            .init(role: .bootImage, relativePath: "a.img", sizeBytes: 1, sha256: "x"),
            .init(role: .bootImage, relativePath: "b.img", sizeBytes: 1, sha256: "y"),
        ]).structuralProblems()
        #expect(problems.contains { $0.contains("bootImage role") })
    }

    @Test("Partition roles classify consistently")
    func roleClassification() {
        #expect(PartitionRole.system.isReadOnly && !PartitionRole.system.isWritable)
        #expect(PartitionRole.userdata.isWritable && !PartitionRole.userdata.isReadOnly)
        #expect(PartitionRole.kernel.isDerived && !PartitionRole.kernel.isBlockDevice)
        for role in PartitionRole.allCases {
            #expect(!(role.isReadOnly && role.isWritable), "\(role) is both read-only and writable")
        }
    }
}

@Suite("Image store")
struct ImageStoreTests {

    @Test("A freshly installed image set verifies clean")
    func verifiesClean() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let report = try set.store.verify(set.identifier)
        #expect(report.isIntact, "\(report.problems)")
        #expect(report.checkedFiles == 4)
        #expect(set.store.installedImageIdentifiers() == [set.identifier])
    }

    @Test("A single flipped byte fails verification and names the file")
    func detectsCorruption() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }

        let systemURL = set.store.directory(for: set.identifier).appendingPathComponent("system.img")
        var data = try Data(contentsOf: systemURL)
        data[10] ^= 0xFF
        try data.write(to: systemURL)

        let report = try set.store.verify(set.identifier)
        #expect(!report.isIntact)
        #expect(report.problems.contains { $0.contains("system.img") && $0.contains("Integrity check failed") })
        // A corrupt image must never be described as merely suspicious.
        #expect(report.problems.contains { $0.contains("will not be booted") })
    }

    @Test("A truncated file fails on size before hashing")
    func detectsTruncation() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let url = set.store.directory(for: set.identifier).appendingPathComponent("userdata.img")
        try Data(count: 16).write(to: url)
        let report = try set.store.verify(set.identifier)
        #expect(report.problems.contains { $0.contains("userdata.img") })
    }

    @Test("Unpacking extracts the kernel byte for byte")
    func unpackKernel() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let result = try set.store.unpackBootImages(for: set.identifier)
        #expect(try Data(contentsOf: result.kernelURL) == set.kernel)
        #expect(result.detectedHeaderVersion == 4)
    }

    @Test("Unpacking concatenates the vendor ramdisk before the generic ramdisk")
    func ramdiskConcatenationOrder() throws {
        // Order is load-bearing: Linux extracts concatenated cpio archives in
        // sequence with later entries winning, so the generic ramdisk must come
        // last to be able to override vendor files.
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let result = try set.store.unpackBootImages(for: set.identifier)
        let ramdiskURL = try #require(result.ramdiskURL)
        let combined = try Data(contentsOf: ramdiskURL)
        #expect(combined.count == set.vendorRamdisk.count + set.genericRamdisk.count)
        #expect(combined.prefix(set.vendorRamdisk.count) == set.vendorRamdisk)
        #expect(combined.suffix(set.genericRamdisk.count) == set.genericRamdisk)
    }

    @Test("Unpacking without a vendor boot image yields the generic ramdisk alone")
    func unpackWithoutVendorBoot() throws {
        let set = try TemporaryImageSet(includeVendorBoot: false)
        defer { set.cleanUp() }
        let result = try set.store.unpackBootImages(for: set.identifier)
        let ramdiskURL = try #require(result.ramdiskURL)
        #expect(try Data(contentsOf: ramdiskURL) == set.genericRamdisk)
        #expect(result.vendorBootCommandLine == nil)
    }

    @Test("Unpacking is idempotent")
    func unpackIsIdempotent() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let first = try set.store.unpackBootImages(for: set.identifier)
        let firstBytes = try Data(contentsOf: first.kernelURL)
        let second = try set.store.unpackBootImages(for: set.identifier)
        #expect(try Data(contentsOf: second.kernelURL) == firstBytes)
        #expect(first == second)
    }

    @Test("Asking for an image that is not installed fails by name")
    func unknownImage() {
        let store = ImageStore(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(throws: ImageStore.Failure.self) { try store.manifest(for: "nope") }
    }

    @Test("SHA-256 streaming matches a known digest")
    func sha256KnownVector() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ImageStore.sha256(ofFileAt: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite("Android guest plan")
struct AndroidGuestPlanTests {

    @Test("The command line always carries a console and keeps kernel messages visible")
    func baseArguments() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let plan = AndroidGuestPlan(manifest: try set.store.manifest(for: set.identifier), store: set.store)
        let arguments = plan.kernelCommandLine(unpack: nil)
        #expect(arguments.contains("console=ttyAMA0"))
        #expect(arguments.contains("printk.devkmsg=on"))
    }

    @Test("Bring-up arguments appear only in bring-up mode")
    func bringUpArguments() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let manifest = try set.store.manifest(for: set.identifier)

        let normal = AndroidGuestPlan(manifest: manifest, store: set.store).kernelCommandLine(unpack: nil)
        #expect(!normal.contains("androidboot.selinux=permissive"))

        let bringUp = AndroidGuestPlan(manifest: manifest, store: set.store, bringUpMode: true)
            .kernelCommandLine(unpack: nil)
        #expect(bringUp.contains("androidboot.selinux=permissive"))
    }

    @Test("Repeated keys keep the last value, so image settings override generic ones")
    func lastValueWins() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        var manifest = try set.store.manifest(for: set.identifier)
        manifest.requiredKernelArguments = ["console=ttyS0", "androidboot.hardware=override"]

        let plan = AndroidGuestPlan(manifest: manifest, store: set.store)
        let arguments = plan.kernelCommandLine(unpack: nil)
        #expect(arguments.contains("console=ttyS0"))
        #expect(!arguments.contains("console=ttyAMA0"))
        #expect(arguments.filter { $0.hasPrefix("console=") }.count == 1)
    }

    @Test("Image command lines are folded in and de-duplicated")
    func imageCommandLinesAreUsed() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let manifest = try set.store.manifest(for: set.identifier)
        let unpack = try set.store.unpackBootImages(for: set.identifier)
        let arguments = AndroidGuestPlan(manifest: manifest, store: set.store).kernelCommandLine(unpack: unpack)
        #expect(arguments.contains("androidboot.boot_devices=a003e00.virtio_mmio"))
        #expect(arguments.filter { $0.hasPrefix("androidboot.hardware=") }.count == 1)
    }

    @Test("Read-only and writable partitions are separated and ordered stably")
    func partitionOrdering() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let plan = AndroidGuestPlan(manifest: try set.store.manifest(for: set.identifier), store: set.store)
        let partitions = plan.attachedPartitions()
        #expect(partitions.readOnly.map(\.lastPathComponent) == ["system.img"])
        #expect(partitions.writable.map(\.lastPathComponent) == ["userdata.img"])
    }

    @Test("A corrupt image is refused before a start request is produced")
    func corruptImageRefused() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let url = set.store.directory(for: set.identifier).appendingPathComponent("system.img")
        var data = try Data(contentsOf: url)
        data[0] ^= 0xFF
        try data.write(to: url)

        let plan = AndroidGuestPlan(manifest: try set.store.manifest(for: set.identifier), store: set.store)
        #expect(throws: MultiemuError.self) {
            try plan.makeStartRequest(
                resources: .defaultProfile(vcpuCount: 4),
                acceleration: .hardwareVirtualization
            )
        }
    }

    @Test("The composite layout attaches one writable overlay, never the shared base",
          .enabled(if: diskToolAvailable))
    func compositeLayoutStartRequest() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let plan = AndroidGuestPlan(
            manifest: try set.store.manifest(for: set.identifier),
            store: set.store,
            layout: .compositeGPTDisk,
            userdataSizeBytes: 1 * ByteCount.giB,
            privateStorage: try set.privateStorage()
        )
        let request = try plan.makeStartRequest(
            resources: .defaultProfile(vcpuCount: 4),
            acceleration: .hardwareVirtualization
        )
        #expect(request.disks.count == 1)
        let disk = try #require(request.disks.first)
        // The composite carries userdata inside it, so it cannot be attached
        // writable while shared between devices. The base is built once and
        // stays read-only; the device writes into its own overlay above it.
        #expect(disk.format == .qcow2)
        #expect(!disk.isReadOnly)
        #expect(disk.url.lastPathComponent == "composite.qcow2")
        #expect(!disk.url.path.hasPrefix(set.store.directory(for: set.identifier).path))
        // And the shared base still exists, unattached.
        #expect(FileManager.default.fileExists(atPath: plan.compositeDiskURL.path))
    }

    @Test("Two devices on one image get separate overlays over a shared base",
          .enabled(if: diskToolAvailable))
    func twoDevicesShareOneBase() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let manifest = try set.store.manifest(for: set.identifier)

        func request(forDevice device: String) throws -> GuestStartRequest {
            try AndroidGuestPlan(
                manifest: manifest, store: set.store,
                privateStorage: try set.privateStorage(device: device)
            ).makeStartRequest(
                resources: .defaultProfile(vcpuCount: 4),
                acceleration: .hardwareVirtualization
            )
        }

        let a = try request(forDevice: "device-a")
        let b = try request(forDevice: "device-b")

        // The read-only image is the same file for both — shared, not copied.
        let sharedA = a.disks.filter(\.isReadOnly).map(\.url.path)
        let sharedB = b.disks.filter(\.isReadOnly).map(\.url.path)
        #expect(sharedA == sharedB)
        #expect(!sharedA.isEmpty)

        // The writable overlays are distinct files, so neither device takes a
        // write lock the other one needs.
        let writableA = try #require(a.disks.first { !$0.isReadOnly }).url
        let writableB = try #require(b.disks.first { !$0.isReadOnly }).url
        #expect(writableA != writableB)
        #expect(FileManager.default.fileExists(atPath: writableA.path))
        #expect(FileManager.default.fileExists(atPath: writableB.path))
    }

    @Test("The composite disk path reflects what actually goes into it")
    func compositePathReflectsItsContents() throws {
        // The layout depends on the userdata size and the A/B slot, both per
        // device. One shared name meant a device configured for 64 GiB could
        // silently adopt a 32 GiB disk built for another: the file exists, so it
        // is reused, and nothing reports the mismatch.
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let manifest = try set.store.manifest(for: set.identifier)

        func plan(userdataGiB: UInt64, slot: String) -> AndroidGuestPlan {
            AndroidGuestPlan(
                manifest: manifest, store: set.store, layout: .compositeGPTDisk,
                userdataSizeBytes: userdataGiB * ByteCount.giB, slotSuffix: slot)
        }

        let small = plan(userdataGiB: 32, slot: "_a").compositeDiskURL
        let large = plan(userdataGiB: 64, slot: "_a").compositeDiskURL
        let otherSlot = plan(userdataGiB: 32, slot: "_b").compositeDiskURL

        #expect(small != large, "a different userdata size must not share a disk")
        #expect(small != otherSlot, "a different slot must not share a disk")
        // The same configuration still resolves to the same file, so userdata
        // survives a restart.
        #expect(small == plan(userdataGiB: 32, slot: "_a").compositeDiskURL)
    }

    @Test("An existing composite disk is reused, so userdata survives a restart")
    func compositeDiskIsNotRebuilt() throws {
        // Rebuilding on every start would silently factory-reset the device.
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let plan = AndroidGuestPlan(
            manifest: try set.store.manifest(for: set.identifier),
            store: set.store, layout: .compositeGPTDisk,
            userdataSizeBytes: 512 * ByteCount.miB
        )
        let first = try plan.ensureCompositeDisk()

        // Write a marker into the userdata partition, as a running guest would.
        let userdata = try #require(first.partitions.first { $0.name == "userdata" })
        let handle = try FileHandle(forWritingTo: first.diskURL)
        try handle.seek(toOffset: userdata.byteOffset)
        try handle.write(contentsOf: Data("MULTIEMU-USERDATA-MARKER".utf8))
        try handle.close()

        _ = try plan.ensureCompositeDisk()

        let reader = try FileHandle(forReadingFrom: first.diskURL)
        try reader.seek(toOffset: userdata.byteOffset)
        let readBack = try reader.read(upToCount: 24) ?? Data()
        try reader.close()
        #expect(String(decoding: readBack, as: UTF8.self) == "MULTIEMU-USERDATA-MARKER")
    }

    @Test("Composite partition names carry the A/B slot suffix")
    func compositePartitionNames() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let partitions = AndroidCompositeLayout.partitions(
            manifest: try set.store.manifest(for: set.identifier),
            store: set.store, slotSuffix: "_a",
            userdataSizeBytes: 1 * ByteCount.giB
        )
        let names = Set(partitions.map(\.name))
        #expect(names.contains("boot_a"))
        #expect(names.contains("vendor_boot_a"))
        // Android's bootloader-message handling needs misc to exist.
        #expect(names.contains("misc"))
        #expect(names.contains("userdata"))
        #expect(names.contains("metadata"))
    }

    @Test("A valid image produces a start request wired for direct kernel boot",
          .enabled(if: diskToolAvailable))
    func startRequest() throws {
        let set = try TemporaryImageSet()
        defer { set.cleanUp() }
        let plan = AndroidGuestPlan(
            manifest: try set.store.manifest(for: set.identifier),
            store: set.store,
            privateStorage: try set.privateStorage()
        )
        let request = try plan.makeStartRequest(
            resources: .defaultProfile(vcpuCount: 4),
            acceleration: .hardwareVirtualization,
            adbHostPort: 5555
        )
        #expect(request.kernelURL?.lastPathComponent == "kernel")
        #expect(request.initialRamdiskURL?.lastPathComponent == "ramdisk")
        #expect(request.disks.count == 2)

        // The read-only partition is attached from the shared image store
        // itself: several devices opening one file read-only is exactly what
        // QEMU permits, and it is what "shared, not copied" means.
        let shared = request.disks.filter(\.isReadOnly)
        #expect(shared.map(\.url.lastPathComponent) == ["system.img"])
        #expect(shared.allSatisfy { $0.format == .raw })
        #expect(shared.allSatisfy { $0.url.path.hasPrefix(set.store.directory(for: set.identifier).path) })

        // The writable partition is this device's own overlay. Attaching the
        // store's userdata.img directly would take a write lock on a shared
        // file and lock every other device out of that image.
        //
        // The `-overlay` suffix is required, not cosmetic. This expectation
        // used to read `userdata.qcow2`, which is the same name
        // `VirtualDeviceStore.create` gives the blank disk it makes for the
        // generic path — so the test asserted precisely the collision that
        // stopped every Android device from starting:
        //
        //     An overlay already exists here but is backed by nothing rather
        //     than …/userdata.img.
        let writable = request.disks.filter { !$0.isReadOnly }
        #expect(writable.map(\.url.lastPathComponent) == ["userdata-overlay.qcow2"])
        #expect(writable.allSatisfy { $0.format == .qcow2 })
        #expect(writable.allSatisfy { !$0.url.path.hasPrefix(set.store.directory(for: set.identifier).path) })
        #expect(request.adbHostPort == 5555)
        #expect(request.guestArchitecture == .arm64)
        // Android first boot is minutes, not the 45 s cold-boot product target.
        #expect(request.bootTimeout >= .seconds(120))
    }
}

@Suite("Per-device overlays do not collide with the device's own disks",
       .enabled(if: diskToolAvailable))
struct OverlayNamingTests {

    @Test("An overlay over userdata.img is not named userdata.qcow2")
    func overlayDoesNotTakeTheDeviceDiskName() throws {
        // The collision this pins, reported from a real run:
        //
        //   Could not create the virtual disk at …/userdata.qcow2: An overlay
        //   already exists here but is backed by nothing rather than
        //   …/images/…/userdata.img. Remove it, or use a different path;
        //   adopting it would boot the wrong disk.
        //
        // `VirtualDeviceStore.create` makes a blank `userdata.qcow2` because on
        // the generic path a device owns its disk outright. An Android image
        // brings its own `userdata.img` and wants an overlay over it. Both
        // wanted that one name; creation runs first, so starting the device
        // failed every time.
        let images = try TemporaryImageSet()
        defer { try? FileManager.default.removeItem(at: images.root) }
        let storage = try images.privateStorage()

        let source = images.root.appendingPathComponent("userdata.img")
        try Data(repeating: 0, count: 1024 * 1024).write(to: source)

        let overlay = try storage.ensureOverlay(over: source)
        #expect(overlay.lastPathComponent != "userdata.qcow2",
                "an overlay must not claim the filename the device store uses for its own disk")
        #expect(overlay.lastPathComponent == "userdata-overlay.qcow2")
    }

    @Test("Overlays over different partitions still get distinct names")
    func overlaysStayDistinct() throws {
        // The suffix must not collapse two partitions onto one file — that was
        // the original reason for naming overlays after their source.
        let images = try TemporaryImageSet()
        defer { try? FileManager.default.removeItem(at: images.root) }
        let storage = try images.privateStorage()

        var names: Set<String> = []
        for partition in ["userdata", "metadata", "misc"] {
            let source = images.root.appendingPathComponent("\(partition).img")
            try Data(repeating: 0, count: 512 * 1024).write(to: source)
            names.insert(try storage.ensureOverlay(over: source).lastPathComponent)
        }
        #expect(names.count == 3)
    }
}

@Suite("An Android start request carries what the guest needs to finish booting",
       .enabled(if: diskToolAvailable))
struct AndroidConsolePortTests {

    @Test("The request configures the console ports Android's HALs open")
    func requestCarriesConsolePorts() throws {
        // The failure this pins, reported from the application:
        //
        //   Failed: The guest did not finish booting within 180 seconds.
        //   Last recognised milestone: androidSecondStage. Guest console ports
        //   — none configured; an Android guest stalls without the ports its
        //   HALs expect.
        //
        // The backend has had `GuestConsolePort.bank` all along and the plan
        // never called it, so every boot from the interface stalled in
        // second-stage init until the timeout. The scripts passed the ports by
        // hand, which is why this never showed up outside the app.
        let images = try TemporaryImageSet()
        defer { try? FileManager.default.removeItem(at: images.root) }

        let plan = AndroidGuestPlan(
            manifest: try images.store.manifest(for: images.identifier),
            store: images.store,
            privateStorage: try images.privateStorage())
        let request = try plan.makeStartRequest(
            resources: .init(memoryBytes: 2 * ByteCount.giB,
                             storageBytes: 8 * ByteCount.giB,
                             vcpuCount: 2),
            acceleration: .hardwareVirtualization)

        #expect(request.consolePorts.count == 20, "Cuttlefish HALs open /dev/hvc0 upward")
        #expect(request.consolePorts[18].service == GuestConsolePort.Service.sensors,
                "the sensors multihal blocks system_server until hvc18 answers")
        #expect(request.consolePorts[1].service == GuestConsolePort.Service.androidConsole,
                "androidboot.console=hvc1 names this port")
        // Every other port exists but stays silent: a HAL that only needs the
        // node to exist must still find it.
        let others = request.consolePorts.enumerated()
            .filter { $0.offset != 18 && $0.offset != 1 }
            .map { $0.element.service }
        #expect(others.allSatisfy { $0 == GuestConsolePort.Service.silent })
    }
}
