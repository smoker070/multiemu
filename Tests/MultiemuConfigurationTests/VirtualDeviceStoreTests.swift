import Foundation
import MultiemuBackend
import MultiemuDisks
import MultiemuSupport
import Testing
@testable import MultiemuConfiguration

/// Disk-backed tests need `qemu-img`, which ships with QEMU. They are enabled
/// conditionally so the suite still runs on a machine without a development
/// QEMU rather than failing for an unrelated reason.
let diskToolAvailable = VirtualDiskManager.locateDevelopmentTool() != nil

@Suite("Virtual device profiles")
struct VirtualDeviceProfileTests {

    private func profile(name: String = "Test device", image: String = "img") -> VirtualDeviceProfile {
        VirtualDeviceProfile(name: name, imageIdentifier: image, guestArchitecture: .arm64)
    }

    @Test("A default profile is valid and carries the product defaults")
    func defaults() {
        let device = profile()
        #expect(device.problems().isEmpty)
        #expect(device.memoryBytes == 4 * ByteCount.giB)
        #expect(device.storageBytes == 32 * ByteCount.giB)
        #expect(device.display == .default)
        #expect(device.network.mode == .userMode)
    }

    @Test("A profile round-trips through JSON with dates intact")
    func codableRoundTrip() throws {
        // Fractional seconds matter: plain .iso8601 truncates, which makes a
        // reloaded modification date earlier than the value it came from.
        let original = profile()
        let decoded = try ConfigurationCoders.makeDecoder()
            .decode(VirtualDeviceProfile.self, from: try ConfigurationCoders.makeEncoder().encode(original))
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.display == original.display)
        #expect(decoded.network == original.network)
        #expect(abs(decoded.createdAt.timeIntervalSince(original.createdAt)) < 0.001,
                "dates must survive a round trip at sub-second precision")
    }

    @Test("Structural problems are reported without touching the host")
    func structuralProblems() {
        // Host-dependent checks stay in ResourceValidator, so a profile remains
        // portable between Macs.
        var device = profile(name: "  ")
        #expect(device.problems().contains { $0.contains("no name") })

        device = profile(image: "")
        #expect(device.problems().contains { $0.contains("does not reference an image") })

        device = profile()
        device.display = DisplayProfile(widthInPixels: 100, heightInPixels: 100, densityDPI: 160)
        #expect(!device.problems().isEmpty)

        device = profile()
        device.storageBytes = 1024
        #expect(device.problems().contains { $0.contains("below the minimum") })

        device = profile()
        device.network = GuestNetworkConfiguration(portForwards: [.init(label: "x", hostPort: 80, guestPort: 8080)])
        #expect(device.problems().contains { $0.contains("privileged") })
    }

    @Test("Resources convert to the preflight request the backend validates")
    func resourcesBridge() {
        let device = profile()
        #expect(device.resources.memoryBytes == device.memoryBytes)
        #expect(device.resources.vcpuCount == device.vcpuCount)
    }
}

@Suite("Virtual device store", .enabled(if: diskToolAvailable))
struct VirtualDeviceStoreTests {

    private func makeStore() throws -> (VirtualDeviceStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-devices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let disks = try #require(VirtualDiskManager.locateDevelopmentTool())
        return (VirtualDeviceStore(root: root, disks: disks), root)
    }

    private func profile(name: String = "Device A", storage: UInt64 = 4 * ByteCount.giB) -> VirtualDeviceProfile {
        VirtualDeviceProfile(name: name, imageIdentifier: "test-image",
                             guestArchitecture: .arm64, storageBytes: storage)
    }

    @Test("The audio setting survives a save and reload")
    func audioSettingPersists() throws {
        // The half of a settings toggle that fails quietly: the control moves,
        // the profile is updated in memory, and nothing reaches disk — so the
        // guest starts next time without the device and the setting appears to
        // have been ignored.
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var created = try store.create(profile(name: "With sound"))
        #expect(created.audioMode == .disabled, "new devices have no sound device")

        created.audioEnabled = true
        _ = try store.save(created)

        // Read back from disk by id, not from the value just written.
        let reloaded = try store.load(created.id)
        #expect(reloaded.audioEnabled == true)
        #expect(reloaded.audioMode == .hostOutput,
                "the backend must ask for a sound device on the next start")
    }

    @Test("Creating a device writes a profile and its writable partitions")
    func creation() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try store.create(profile())
        #expect(FileManager.default.fileExists(atPath: store.profileURL(for: device.id).path))
        #expect(FileManager.default.fileExists(atPath: store.userdataURL(for: device.id).path))
        #expect(FileManager.default.fileExists(atPath: store.metadataURL(for: device.id).path))
        #expect(store.list().count == 1)
        #expect(try store.load(device.id).name == "Device A")
    }

    @Test("userdata is created sparse, not fully allocated")
    func userdataIsSparse() throws {
        // The product rule: a 32 GiB device must not cost 32 GiB up front.
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try store.create(profile(storage: 32 * ByteCount.giB))
        let disk = try store.disks.inspect(at: store.userdataURL(for: device.id))
        #expect(disk.logicalSizeBytes == 32 * ByteCount.giB)
        #expect(disk.format == .qcow2)
        let allocated = try #require(disk.allocatedBytes())
        #expect(allocated < 8 * ByteCount.miB, "allocated \(ByteCount.describe(allocated)) for a 32 GiB disk")
        #expect(disk.isSparse())
    }

    @Test("Two devices cannot share a name")
    func duplicateNames() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.create(profile())
        #expect(throws: VirtualDeviceStore.Failure.self) { try store.create(profile()) }
    }

    @Test("An invalid profile is refused before anything is written")
    func invalidProfileRefused() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var broken = profile()
        broken.display = DisplayProfile(widthInPixels: 1, heightInPixels: 1, densityDPI: 1)
        #expect(throws: VirtualDeviceStore.Failure.self) { try store.create(broken) }
        #expect(store.list().isEmpty)
    }

    @Test("Factory reset recreates userdata but keeps the profile")
    func factoryReset() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let device = try store.create(profile())
        // Write into the disk file as a running guest would.
        let handle = try FileHandle(forWritingTo: store.userdataURL(for: device.id))
        try handle.seek(toOffset: 1 * ByteCount.miB)
        try handle.write(contentsOf: Data("GUEST DATA".utf8))
        try handle.close()
        let dirtied = try #require(store.disks.inspect(at: store.userdataURL(for: device.id)).allocatedBytes())

        try store.factoryReset(device.id)

        let reset = try #require(store.disks.inspect(at: store.userdataURL(for: device.id)).allocatedBytes())
        #expect(reset < dirtied, "factory reset did not shrink the disk back")
        // The device itself survives, so the user does not reconfigure it.
        #expect(try store.load(device.id).name == "Device A")
        #expect(try store.load(device.id).display == .default)
    }

    @Test("Deleting a device removes everything it owns")
    func deletion() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try store.create(profile())
        try store.delete(device.id)
        #expect(store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: device.id).path))
        #expect(throws: VirtualDeviceStore.Failure.self) { try store.load(device.id) }
    }

    @Test("Writable disks are reported as qcow2 and not read-only")
    func writableDisks() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try store.create(profile())
        let disks = store.writableDisks(for: device.id)
        #expect(disks.count == 2)
        #expect(disks.allSatisfy { $0.format == .qcow2 && !$0.isReadOnly })
    }

    @Test("Saving updates the modification date and keeps the identity")
    func saving() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var device = try store.create(profile())
        let originalModified = device.modifiedAt
        device.name = "Renamed"
        try store.save(device)
        let reloaded = try store.load(device.id)
        #expect(reloaded.name == "Renamed")
        #expect(reloaded.id == device.id)
        #expect(reloaded.modifiedAt >= originalModified)
    }
}

@Suite("Virtual disks", .enabled(if: diskToolAvailable))
struct VirtualDiskManagerTests {

    private func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-disk-\(UUID().uuidString).qcow2")
    }

    @Test("A created disk reports the right format and logical size")
    func creation() throws {
        let manager = try #require(VirtualDiskManager.locateDevelopmentTool())
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let disk = try manager.create(at: url, format: .qcow2, sizeBytes: 8 * ByteCount.giB)
        #expect(disk.exists())
        let inspected = try manager.inspect(at: url)
        #expect(inspected.format == .qcow2)
        #expect(inspected.logicalSizeBytes == 8 * ByteCount.giB)
    }

    @Test("An existing disk is never silently overwritten")
    func neverOverwrites() throws {
        // Overwriting a disk is indistinguishable from a factory reset the user
        // did not ask for, so it is refused rather than defaulted.
        let manager = try #require(VirtualDiskManager.locateDevelopmentTool())
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try manager.create(at: url, sizeBytes: 1 * ByteCount.giB)
        #expect(throws: VirtualDiskManager.Failure.self) {
            try manager.create(at: url, sizeBytes: 2 * ByteCount.giB)
        }
    }

    @Test("ensure() is idempotent and does not resize an existing disk")
    func ensureIsIdempotent() throws {
        let manager = try #require(VirtualDiskManager.locateDevelopmentTool())
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try manager.ensure(at: url, sizeBytes: 1 * ByteCount.giB)
        let second = try manager.ensure(at: url, sizeBytes: 16 * ByteCount.giB)
        #expect(second.logicalSizeBytes == first.logicalSizeBytes)
    }

    @Test("An absurdly small disk is refused as a probable units mistake")
    func minimumSize() throws {
        let manager = try #require(VirtualDiskManager.locateDevelopmentTool())
        #expect(throws: VirtualDiskManager.Failure.self) {
            try manager.create(at: temporaryURL(), sizeBytes: 1024)
        }
    }

    @Test("A raw disk of the same logical size is also sparse on APFS")
    func rawIsSparseToo() throws {
        let manager = try #require(VirtualDiskManager.locateDevelopmentTool())
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = try manager.create(at: url, format: .raw, sizeBytes: 4 * ByteCount.giB)
        #expect(disk.isSparse())
        #expect((disk.fileSizeBytes() ?? 0) == 4 * ByteCount.giB)
        #expect((disk.allocatedBytes() ?? .max) < 8 * ByteCount.miB)
    }
}
