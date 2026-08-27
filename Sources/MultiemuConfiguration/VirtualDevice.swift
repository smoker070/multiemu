import Foundation
import MultiemuBackend
import MultiemuDisks
import MultiemuInput
import MultiemuSupport

/// A configured virtual device, persisted between launches.
public struct VirtualDeviceProfile: Sendable, Equatable, Codable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    /// Identifier of the image set in the image store.
    public var imageIdentifier: String
    public var guestArchitecture: GuestArchitecture
    public var memoryBytes: UInt64
    public var storageBytes: UInt64
    public var vcpuCount: Int
    public var display: DisplayProfile
    public var network: GuestNetworkConfiguration
    /// Input mappings saved with this device.
    ///
    /// Optional so that a device file written before input profiles existed
    /// still decodes — the synthesised decoder requires every non-optional key
    /// to be present, and a device that fails to decode disappears from the
    /// user's library.
    public var inputProfiles: [InputProfile]?
    public var activeInputProfileID: UUID?
    /// Whether this device gets a sound device.
    ///
    /// Optional for the same reason `inputProfiles` is: the synthesised decoder
    /// requires every non-optional key, so adding a plain `Bool` would make
    /// every device file written before today fail to decode and vanish from
    /// the user's library.
    ///
    /// **Off by default**, and that is a statement about the images rather than
    /// about the feature. The guest binds the device happily, but the Android
    /// images this project runs use AOSP's example audio HAL, which never
    /// reaches ALSA — so app audio would not come out of it. Attaching a sound
    /// card nothing can play through is a device for nothing.
    public var audioEnabled: Bool?

    /// What the backend should do about sound for this device.
    public var audioMode: GuestAudioMode { audioEnabled == true ? .hostOutput : .disabled }
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        schemaVersion: Int = VirtualDeviceProfile.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        imageIdentifier: String,
        guestArchitecture: GuestArchitecture,
        memoryBytes: UInt64 = 4 * ByteCount.giB,
        storageBytes: UInt64 = 32 * ByteCount.giB,
        vcpuCount: Int = 4,
        display: DisplayProfile = .default,
        network: GuestNetworkConfiguration = .default,
        inputProfiles: [InputProfile]? = nil,
        activeInputProfileID: UUID? = nil,
        audioEnabled: Bool? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.imageIdentifier = imageIdentifier
        self.guestArchitecture = guestArchitecture
        self.memoryBytes = memoryBytes
        self.storageBytes = storageBytes
        self.vcpuCount = vcpuCount
        self.display = display
        self.network = network
        self.inputProfiles = inputProfiles
        self.activeInputProfileID = activeInputProfileID
        self.audioEnabled = audioEnabled
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var resources: GuestResourceRequest {
        GuestResourceRequest(memoryBytes: memoryBytes, storageBytes: storageBytes, vcpuCount: vcpuCount)
    }

    /// Problems checked without touching disk or the host.
    ///
    /// Host-dependent checks — does this Mac have the memory — stay in
    /// `ResourceValidator`, so a profile remains portable between machines.
    public func problems() -> [String] {
        var problems: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            problems.append("Profile schema version \(schemaVersion) is not \(Self.currentSchemaVersion).")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("The device has no name.")
        }
        if imageIdentifier.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("The device does not reference an image.")
        }
        problems.append(contentsOf: display.problems())
        problems.append(contentsOf: network.problems())
        if storageBytes < VirtualDiskManager.minimumDiskSize {
            problems.append("Storage of \(ByteCount.describe(storageBytes)) is below the minimum.")
        }
        return problems
    }
}

/// JSON coders for on-disk configuration.
///
/// Dates are encoded with **fractional seconds**. Foundation's plain `.iso8601`
/// strategy truncates to whole seconds, which makes a reloaded timestamp
/// earlier than the value it was written from — so a modification date appears
/// to move backwards across a save/load cycle.
enum ConfigurationCoders {
    /// Created per call rather than shared: `ISO8601DateFormatter` is not
    /// `Sendable`, and configuration writes are rare enough that the allocation
    /// is irrelevant next to correctness under strict concurrency.
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeFormatter().string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = makeFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Not an ISO-8601 date with fractional seconds: \(text)"
                )
            }
            return date
        }
        return decoder
    }
}

/// Stores virtual devices on disk and manages their writable partitions.
public struct VirtualDeviceStore: Sendable {

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case deviceNotFound(UUID)
        case profileInvalid([String])
        case nameAlreadyUsed(String)

        public var description: String {
            switch self {
            case let .deviceNotFound(id): return "No virtual device with identifier \(id)."
            case let .profileInvalid(problems): return "The device profile is not usable: \(problems.joined(separator: " "))"
            case let .nameAlreadyUsed(name): return "A device named \"\(name)\" already exists."
            }
        }
    }

    public let root: URL
    public let disks: VirtualDiskManager

    public init(root: URL, disks: VirtualDiskManager) {
        self.root = root
        self.disks = disks
    }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Multiemu", isDirectory: true)
            .appendingPathComponent("devices", isDirectory: true)
    }

    public func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func profileURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("device.json")
    }

    /// Writable partitions live per device; read-only ones are shared from the
    /// image store, which is what lets several devices use one `system.img`.
    public func userdataURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("userdata.qcow2")
    }

    public func metadataURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("metadata.qcow2")
    }

    // MARK: - Lifecycle

    public func list() -> [VirtualDeviceProfile] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return contents
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? load($0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func load(_ id: UUID) throws -> VirtualDeviceProfile {
        guard let data = FileManager.default.contents(atPath: profileURL(for: id).path) else {
            throw Failure.deviceNotFound(id)
        }
        return try ConfigurationCoders.makeDecoder().decode(VirtualDeviceProfile.self, from: data)
    }

    /// Creates a device and its writable partitions.
    @discardableResult
    public func create(_ profile: VirtualDeviceProfile) throws -> VirtualDeviceProfile {
        let problems = profile.problems()
        guard problems.isEmpty else { throw Failure.profileInvalid(problems) }
        guard !list().contains(where: { $0.name == profile.name }) else {
            throw Failure.nameAlreadyUsed(profile.name)
        }

        try FileManager.default.createDirectory(at: directory(for: profile.id), withIntermediateDirectories: true)
        try disks.ensure(at: userdataURL(for: profile.id), format: .qcow2, sizeBytes: profile.storageBytes)
        // Android 10+ needs a metadata partition.
        try disks.ensure(at: metadataURL(for: profile.id), format: .qcow2, sizeBytes: 64 * ByteCount.miB)
        // Return what was actually persisted, so the caller's copy and the file
        // never disagree about the modification date.
        return try save(profile)
    }

    @discardableResult
    public func save(_ profile: VirtualDeviceProfile) throws -> VirtualDeviceProfile {
        var updated = profile
        updated.modifiedAt = Date()
        let problems = updated.problems()
        guard problems.isEmpty else { throw Failure.profileInvalid(problems) }

        try FileManager.default.createDirectory(at: directory(for: profile.id), withIntermediateDirectories: true)
        try ConfigurationCoders.makeEncoder()
            .encode(updated)
            .write(to: profileURL(for: profile.id), options: .atomic)
        return updated
    }

    /// Recreates the writable partitions, leaving the profile intact.
    ///
    /// This is factory reset: read-only partitions are untouched because they
    /// are shared, and the device keeps its name, resources and display so the
    /// user does not have to reconfigure it.
    public func factoryReset(_ id: UUID) throws {
        let profile = try load(id)
        try disks.delete(at: userdataURL(for: id))
        try disks.delete(at: metadataURL(for: id))
        try disks.create(at: userdataURL(for: id), format: .qcow2, sizeBytes: profile.storageBytes)
        try disks.create(at: metadataURL(for: id), format: .qcow2, sizeBytes: 64 * ByteCount.miB)
        MultiemuLog.storage.info("Factory reset \(profile.name, privacy: .public)")
    }

    /// Deletes a device and everything it owns.
    public func delete(_ id: UUID) throws {
        let directory = directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw Failure.deviceNotFound(id)
        }
        try FileManager.default.removeItem(at: directory)
    }

    /// The writable disks a device attaches, in a stable order.
    public func writableDisks(for id: UUID) -> [GuestDiskImage] {
        [userdataURL(for: id), metadataURL(for: id)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { GuestDiskImage(url: $0, format: .qcow2, isReadOnly: false) }
    }
}

extension VirtualDeviceProfile {

    /// The device's input profiles, seeded with a starter layout the first time
    /// they are asked for.
    ///
    /// A device created before input mapping existed has no profiles at all;
    /// rather than showing an empty list, it starts from the same default a new
    /// device would.
    public var effectiveInputProfiles: [InputProfile] {
        if let inputProfiles, !inputProfiles.isEmpty { return inputProfiles }
        return [.starter]
    }

    /// The mapping currently applied, or the first available one.
    public var activeInputProfile: InputProfile? {
        let profiles = effectiveInputProfiles
        if let activeInputProfileID,
           let match = profiles.first(where: { $0.id == activeInputProfileID }) {
            return match
        }
        return profiles.first
    }

    /// Adds or replaces a profile, keeping it selected.
    public mutating func upsertInputProfile(_ profile: InputProfile, makeActive: Bool = true) {
        var profiles = effectiveInputProfiles
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        inputProfiles = profiles
        if makeActive { activeInputProfileID = profile.id }
    }

    /// Removes a profile. The last one is kept: a device with no mapping at all
    /// has no way to get one back through the interface.
    public mutating func removeInputProfile(_ id: UUID) {
        var profiles = effectiveInputProfiles
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        inputProfiles = profiles
        if activeInputProfileID == id { activeInputProfileID = profiles.first?.id }
    }
}
