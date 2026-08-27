import Foundation
import MultiemuBackend
import MultiemuSupport

/// The role a file plays in an Android virtual device.
public enum PartitionRole: String, Codable, Sendable, CaseIterable {
    // NOTE: some roles appear more than once in a real image set. See
    // `allowsMultipleFiles` below.
    // Containers, unpacked at install time.
    case bootImage
    case vendorBootImage
    // Products of unpacking, consumed by direct kernel boot.
    case kernel
    case ramdisk
    case vendorRamdisk
    case combinedRamdisk
    case deviceTree
    // Read-only partitions, shareable between virtual devices.
    case system
    case vendor
    case product
    case systemExt
    case superImage
    case vbmeta
    // Per-device writable partitions.
    case userdata
    case metadata
    case cache

    /// Read-only partitions are opened `readonly=on` so several instances can
    /// share one file. Decided now rather than at the multi-instance milestone,
    /// because retrofitting sharing means rewriting the disk layer.
    public var isReadOnly: Bool {
        switch self {
        case .system, .vendor, .product, .systemExt, .superImage, .vbmeta: return true
        default: return false
        }
    }

    public var isWritable: Bool {
        switch self {
        case .userdata, .metadata, .cache: return true
        default: return false
        }
    }

    /// Files produced by unpacking rather than shipped in the image set.
    /// Whether an image set may legitimately contain several files in this
    /// role.
    ///
    /// Android ships `vbmeta`, `vbmeta_system`, `vbmeta_system_dlkm` and
    /// `vbmeta_vendor_dlkm` — four partitions, one role. Requiring uniqueness
    /// rejected a genuine AOSP image set.
    public var allowsMultipleFiles: Bool {
        self == .vbmeta
    }

    public var isDerived: Bool {
        switch self {
        case .kernel, .ramdisk, .vendorRamdisk, .combinedRamdisk, .deviceTree: return true
        default: return false
        }
    }

    /// Files attached to the guest as block devices.
    public var isBlockDevice: Bool { isReadOnly || isWritable }
}

public struct ManifestFile: Codable, Sendable, Equatable {
    public var role: PartitionRole
    public var relativePath: String
    public var sizeBytes: UInt64
    /// Lowercase hex SHA-256. Verified on install and before every boot.
    public var sha256: String
    /// The Android partition this file becomes, when the role alone does not
    /// say. A real image ships several vbmeta partitions, and naming them from
    /// the role would give them all the same name.
    ///
    /// Optional so manifests written before this existed still decode.
    public var partitionName: String?

    public init(
        role: PartitionRole,
        relativePath: String,
        sizeBytes: UInt64,
        sha256: String,
        partitionName: String? = nil
    ) {
        self.role = role
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.partitionName = partitionName
    }

    /// The partition name to use, falling back to the file's own stem.
    public var effectivePartitionName: String {
        if let partitionName, !partitionName.isEmpty { return partitionName }
        return (relativePath as NSString).lastPathComponent
            .replacingOccurrences(of: ".img", with: "")
    }
}

/// Describes one installed Android image set.
///
/// Provenance and licensing are mandatory fields, not documentation: an image is
/// a kernel plus a userspace that we may or may not have the right to
/// redistribute, and "where did this come from" must be answerable from the
/// artifact itself rather than from someone's memory.
public struct ImageManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var imageIdentifier: String
    public var displayName: String
    public var androidRelease: String
    public var androidAPILevel: Int
    public var guestArchitecture: GuestArchitecture
    /// Where this image came from, verbatim. Required.
    public var source: String
    /// Redistribution status. Required. See docs/DEPENDENCIES-AND-LICENSING.md.
    public var licenseNotice: String
    /// Kernel command line fragments this image needs, beyond the generic ones.
    public var requiredKernelArguments: [String]
    /// How this image expects its partitions to be presented.
    ///
    /// Optional so that manifests written before this existed still decode —
    /// a non-optional key makes every older image vanish from the library.
    ///
    /// It belongs here because it is a property of the image: a Cuttlefish
    /// image mounts through `/dev/block/by-name/…` and needs one GPT disk,
    /// while other images accept a block device per partition. Getting it
    /// wrong does not fail cleanly — first-stage init finds no partitions and
    /// the kernel panics with `Attempted to kill init!`.
    public var partitionLayout: AndroidGuestPlan.PartitionLayout?
    public var files: [ManifestFile]

    public init(
        schemaVersion: Int = ImageManifest.currentSchemaVersion,
        imageIdentifier: String,
        displayName: String,
        androidRelease: String,
        androidAPILevel: Int,
        guestArchitecture: GuestArchitecture,
        source: String,
        licenseNotice: String,
        requiredKernelArguments: [String] = [],
        partitionLayout: AndroidGuestPlan.PartitionLayout? = nil,
        files: [ManifestFile]
    ) {
        self.schemaVersion = schemaVersion
        self.imageIdentifier = imageIdentifier
        self.displayName = displayName
        self.androidRelease = androidRelease
        self.androidAPILevel = androidAPILevel
        self.guestArchitecture = guestArchitecture
        self.source = source
        self.licenseNotice = licenseNotice
        self.requiredKernelArguments = requiredKernelArguments
        self.partitionLayout = partitionLayout
        self.files = files
    }

    public func file(for role: PartitionRole) -> ManifestFile? {
        files.first { $0.role == role }
    }

    /// Product floor is Android 9 (API 28).
    public var meetsMinimumAndroidVersion: Bool { androidAPILevel >= 28 }

    /// Problems that make the image unusable, checked without touching disk.
    public func structuralProblems() -> [String] {
        var problems: [String] = []
        if schemaVersion != Self.currentSchemaVersion {
            problems.append("Manifest schema version \(schemaVersion) is not \(Self.currentSchemaVersion).")
        }
        if !meetsMinimumAndroidVersion {
            problems.append("API level \(androidAPILevel) is below the supported minimum of 28 (Android 9).")
        }
        if file(for: .bootImage) == nil && file(for: .kernel) == nil {
            problems.append("The image set has neither a boot image nor an extracted kernel.")
        }
        if source.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("The manifest does not record where the image came from.")
        }
        if licenseNotice.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("The manifest does not record the image's redistribution status.")
        }
        let grouped = Dictionary(grouping: files.filter { !$0.role.isDerived }, by: \.role)
        for (role, entries) in grouped where entries.count > 1 {
            guard role.allowsMultipleFiles else {
                problems.append("More than one file claims the \(role.rawValue) role.")
                continue
            }
            // A repeatable role still needs distinct partitions, or two files
            // would land on the same one and only the last would survive.
            let names = entries.map(\.effectivePartitionName)
            if Set(names).count != names.count {
                problems.append(
                    "Several \(role.rawValue) files map to the same partition: \(names.sorted().joined(separator: ", ")).")
            }
        }
        return problems
    }
}
