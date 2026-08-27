import Foundation
import MultiemuBackend
import MultiemuSupport

/// Turns a directory of Android partition images into an installed image set.
///
/// The mapping from filename to partition role is a *convention*, so it lives in
/// one table that can be corrected when a real image set disagrees, rather than
/// being scattered through the installer.
public struct ImageInstaller: Sendable {

    /// Recognised filenames, most specific first.
    ///
    /// Names follow AOSP build output. Anything unrecognised is reported rather
    /// than silently ignored — an image set with a partition Multiemu does not
    /// know about is a fact the user needs to see, not one to swallow.
    public static let filenameRoles: [(filename: String, role: PartitionRole)] = [
        ("boot.img", .bootImage),
        ("vendor_boot.img", .vendorBootImage),
        ("init_boot.img", .ramdisk),
        ("super.img", .superImage),
        ("system.img", .system),
        ("system_ext.img", .systemExt),
        ("vendor.img", .vendor),
        ("product.img", .product),
        ("vbmeta.img", .vbmeta),
        ("vbmeta_system.img", .vbmeta),
        ("vbmeta_system_dlkm.img", .vbmeta),
        ("vbmeta_vendor_dlkm.img", .vbmeta),
        ("userdata.img", .userdata),
        ("metadata.img", .metadata),
        ("cache.img", .cache),
    ]

    public struct Plan: Sendable, Equatable {
        public var recognised: [(role: PartitionRole, filename: String, sizeBytes: UInt64)]
        public var unrecognised: [String]

        public static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.unrecognised == rhs.unrecognised
                && lhs.recognised.map(\.filename) == rhs.recognised.map(\.filename)
        }
    }

    public let store: ImageStore

    public init(store: ImageStore) {
        self.store = store
    }

    /// Inspects a directory without copying anything.
    public func plan(forDirectory directory: URL) throws -> Plan {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var recognised: [(PartitionRole, String, UInt64)] = []
        var unrecognised: [String] = []

        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if let match = Self.filenameRoles.first(where: { $0.filename == name }) {
                recognised.append((match.role, name, size))
            } else if name.hasSuffix(".img") {
                unrecognised.append(name)
            }
        }
        return Plan(recognised: recognised, unrecognised: unrecognised)
    }

    /// Copies an image set into the store and writes a verified manifest.
    ///
    /// `source` and `licenseNotice` are required arguments, not optional
    /// metadata: an image whose provenance and redistribution status are unknown
    /// is one we cannot reason about legally or diagnose later.
    @discardableResult
    public func install(
        fromDirectory directory: URL,
        identifier: String,
        displayName: String,
        androidRelease: String,
        androidAPILevel: Int,
        guestArchitecture: GuestArchitecture,
        source: String,
        licenseNotice: String,
        requiredKernelArguments: [String] = [],
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> ImageManifest {

        let plan = try plan(forDirectory: directory)
        guard !plan.recognised.isEmpty else {
            throw ImageStore.Failure.unpackFailed("No recognised Android partition images in \(directory.path).")
        }

        let destination = store.directory(for: identifier)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var files: [ManifestFile] = []
        for entry in plan.recognised {
            progress?("copying \(entry.filename) (\(ByteCount.describe(entry.sizeBytes)))")
            let sourceURL = directory.appendingPathComponent(entry.filename)
            let destinationURL = destination.appendingPathComponent(entry.filename)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            progress?("hashing \(entry.filename)")
            files.append(.init(
                role: entry.role,
                relativePath: entry.filename,
                sizeBytes: entry.sizeBytes,
                sha256: try ImageStore.sha256(ofFileAt: destinationURL),
                // Recorded from the filename, because a role that repeats
                // cannot name its own partition — every vbmeta would be called
                // "vbmeta" and only one would survive.
                partitionName: (entry.filename as NSString).deletingPathExtension
            ))
        }

        let manifest = ImageManifest(
            imageIdentifier: identifier,
            displayName: displayName,
            androidRelease: androidRelease,
            androidAPILevel: androidAPILevel,
            guestArchitecture: guestArchitecture,
            source: source,
            licenseNotice: licenseNotice,
            requiredKernelArguments: requiredKernelArguments,
            files: files
        )

        let problems = manifest.structuralProblems()
        guard problems.isEmpty else {
            throw ImageStore.Failure.manifestInvalid(problems)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: store.manifestURL(for: identifier), options: .atomic)

        // Verify immediately: an install that produced an unverifiable set is a
        // failed install, and must not be discovered at first boot instead.
        let report = try store.verify(identifier)
        guard report.isIntact else {
            throw ImageStore.Failure.manifestInvalid(report.problems)
        }
        progress?("installed \(files.count) files, all verified")
        return manifest
    }
}
