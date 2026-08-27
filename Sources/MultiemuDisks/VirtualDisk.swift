import Foundation
import MultiemuBackend
import MultiemuSupport

/// A virtual disk file backing one guest partition.
public struct VirtualDisk: Sendable, Equatable {

    public enum Format: String, Sendable, Codable, CaseIterable {
        /// Sparse by virtue of the filesystem. Simple, and what Android
        /// partition images already are.
        case raw
        /// Sparse by virtue of the format, plus internal snapshots. The default
        /// for writable partitions because Milestone 15 needs snapshots.
        case qcow2
    }

    public var url: URL
    public var format: Format
    /// Logical size as the guest sees it.
    public var logicalSizeBytes: UInt64

    public init(url: URL, format: Format, logicalSizeBytes: UInt64) {
        self.url = url
        self.format = format
        self.logicalSizeBytes = logicalSizeBytes
    }

    /// Bytes actually occupied on the host filesystem.
    ///
    /// The product rule is that a 32 GiB device must not cost 32 GiB until the
    /// guest has written that much, so this is the number that proves it.
    public func allocatedBytes() -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
              let allocated = values.totalFileAllocatedSize else { return nil }
        return UInt64(max(0, allocated))
    }

    public func fileSizeBytes() -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return UInt64(max(0, size))
    }

    /// Whether the disk occupies materially less space than it claims.
    ///
    /// A freshly created 32 GiB qcow2 is a few hundred KiB; if it is not, sparse
    /// allocation is not working and the user is about to lose a lot of disk.
    public func isSparse() -> Bool {
        guard let allocated = allocatedBytes() else { return false }
        return allocated < logicalSizeBytes / 2
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// Creates and inspects virtual disks using `qemu-img`.
///
/// `qemu-img` is used rather than a hand-written qcow2 writer for the same
/// reason QEMU itself is used rather than a hand-written VMM: the format has
/// version quirks, refcount tables and cluster allocation rules that a
/// from-scratch implementation would get subtly wrong, and a subtly wrong disk
/// loses user data rather than failing loudly.
///
/// It ships alongside QEMU, so it carries the same GPL-2.0 obligations and the
/// same rule: a separate executable invoked as a subprocess, never linked.
public struct VirtualDiskManager: Sendable {

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case toolNotFound
        case creationFailed(path: String, detail: String)
        case alreadyExists(path: String)
        case inspectionFailed(path: String, detail: String)
        case sizeTooSmall(requested: UInt64, minimum: UInt64)

        public var description: String {
            switch self {
            case .toolNotFound:
                return "qemu-img was not found. Install a development QEMU with `brew install qemu`, or use the bundled helper."
            case let .creationFailed(path, detail):
                return "Could not create the virtual disk at \(path): \(detail)"
            case let .alreadyExists(path):
                return "A disk already exists at \(path). Deleting it would destroy guest data, so it is left alone."
            case let .inspectionFailed(path, detail):
                return "Could not inspect \(path): \(detail)"
            case let .sizeTooSmall(requested, minimum):
                return "\(ByteCount.describe(requested)) is below the \(ByteCount.describe(minimum)) minimum for a virtual disk."
            }
        }
    }

    /// Smallest disk worth creating. Below this nothing Android needs will fit,
    /// and the request is almost certainly a units mistake.
    public static let minimumDiskSize: UInt64 = 64 * ByteCount.miB

    public let toolURL: URL

    public init(toolURL: URL) {
        self.toolURL = toolURL
    }

    /// Locates a development `qemu-img`.
    public static func locateDevelopmentTool() -> VirtualDiskManager? {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = (directory as NSString).appendingPathComponent("qemu-img")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return VirtualDiskManager(toolURL: URL(fileURLWithPath: candidate))
            }
        }
        return nil
    }

    /// Creates a disk, refusing to overwrite an existing one.
    ///
    /// Never overwrites: a disk file is user data, and silently replacing one is
    /// indistinguishable from a factory reset the user did not ask for.
    @discardableResult
    public func create(
        at url: URL,
        format: VirtualDisk.Format = .qcow2,
        sizeBytes: UInt64
    ) throws -> VirtualDisk {
        guard sizeBytes >= Self.minimumDiskSize else {
            throw Failure.sizeTooSmall(requested: sizeBytes, minimum: Self.minimumDiskSize)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.alreadyExists(path: url.path)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let result = try run(["create", "-f", format.rawValue, url.path, "\(sizeBytes)"])
        guard result.status == 0 else {
            throw Failure.creationFailed(path: url.path, detail: result.output)
        }

        let disk = VirtualDisk(url: url, format: format, logicalSizeBytes: sizeBytes)
        MultiemuLog.storage.info("""
            Created \(format.rawValue, privacy: .public) disk \(url.lastPathComponent, privacy: .public) \
            logical \(ByteCount.describe(sizeBytes), privacy: .public), \
            allocated \(ByteCount.describe(disk.allocatedBytes() ?? 0), privacy: .public)
            """)
        return disk
    }

    /// Creates a copy-on-write overlay over a **shared, read-only** base image.
    ///
    /// This is what lets several devices boot the same guest image without each
    /// one copying it: QEMU opens a backing file read-only, and read-only
    /// openers do not exclude one another (docs/VERIFY.md,
    /// `QEMU-SHARES-READ-ONLY-IMAGES`). Each device writes only into its own
    /// overlay, which starts at a couple of hundred kilobytes.
    ///
    /// The base must never be opened writable by anything, or every device
    /// holding an overlay over it is locked out.
    @discardableResult
    public func createOverlay(
        at url: URL,
        backedBy base: URL,
        baseFormat: VirtualDisk.Format
    ) throws -> VirtualDisk {
        guard FileManager.default.fileExists(atPath: base.path) else {
            throw Failure.creationFailed(path: url.path, detail: "Backing image not found at \(base.path)")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.alreadyExists(path: url.path)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        // The backing format is stated explicitly: qemu-img warns that probing
        // it is unsafe, and this project already refuses to probe image formats
        // anywhere else for the same reason.
        let result = try run([
            "create", "-f", VirtualDisk.Format.qcow2.rawValue,
            "-b", base.path, "-F", baseFormat.rawValue, url.path,
        ])
        guard result.status == 0 else {
            throw Failure.creationFailed(path: url.path, detail: result.output)
        }

        let disk = try inspect(at: url)
        MultiemuLog.storage.info("""
            Created overlay \(url.lastPathComponent, privacy: .public) over shared base \
            \(base.lastPathComponent, privacy: .public), allocated \
            \(ByteCount.describe(disk.allocatedBytes() ?? 0), privacy: .public)
            """)
        return disk
    }

    /// Reads the backing file an overlay actually points at, if any.
    public func backingFile(at url: URL) throws -> String? {
        let result = try run(["info", "--force-share", "--output=json", url.path])
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["backing-filename"] as? String
    }

    /// Creates the overlay only if it is absent, and returns it either way.
    ///
    /// An existing file at that path is **verified** to back the requested base
    /// before it is adopted. Adopting it blindly is how a device silently boots
    /// somebody else's disk: overlay names are derived from the source's
    /// filename, so two different bases can want the same overlay name, and a
    /// base that was replaced leaves an overlay pointing at something that no
    /// longer exists.
    @discardableResult
    public func ensureOverlay(
        at url: URL,
        backedBy base: URL,
        baseFormat: VirtualDisk.Format
    ) throws -> VirtualDisk {
        if FileManager.default.fileExists(atPath: url.path) {
            let expected = base.resolvingSymlinksInPath().standardizedFileURL.path

            var actual: String?
            if let reported = try backingFile(at: url) {
                actual = URL(fileURLWithPath: reported)
                    .resolvingSymlinksInPath().standardizedFileURL.path
            }

            guard actual == expected else {
                throw Failure.creationFailed(
                    path: url.path,
                    detail: """
                        An overlay already exists here but is backed by \
                        \(actual ?? "nothing") rather than \(expected). Remove it, or use a \
                        different path; adopting it would boot the wrong disk.
                        """)
            }
            return try inspect(at: url)
        }
        return try createOverlay(at: url, backedBy: base, baseFormat: baseFormat)
    }

    /// Creates the disk only if it is absent, and returns it either way.
    @discardableResult
    public func ensure(
        at url: URL,
        format: VirtualDisk.Format = .qcow2,
        sizeBytes: UInt64
    ) throws -> VirtualDisk {
        if FileManager.default.fileExists(atPath: url.path) {
            return try inspect(at: url)
        }
        return try create(at: url, format: format, sizeBytes: sizeBytes)
    }

    /// Reads a disk's real format and logical size from the file itself.
    public func inspect(at url: URL) throws -> VirtualDisk {
        // `--force-share` so a disk currently open by a running guest can still
        // be read. Without it qemu-img refuses with "Failed to get shared
        // 'write' lock", which surfaces as an empty result rather than an
        // error. Safe here because every use is a read-only query.
        let result = try run(["info", "--output=json", "--force-share", url.path])
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.inspectionFailed(path: url.path, detail: result.output)
        }
        let formatName = object["format"] as? String ?? "raw"
        let virtualSize = (object["virtual-size"] as? NSNumber)?.uint64Value ?? 0
        return VirtualDisk(
            url: url,
            format: VirtualDisk.Format(rawValue: formatName) ?? .raw,
            logicalSizeBytes: virtualSize
        )
    }

    /// Lists the internal snapshots stored in a qcow2 image.
    ///
    /// Read from the file rather than over QMP, so a stopped device can still
    /// show its snapshots.
    public func snapshots(at url: URL) throws -> [SnapshotHandle] {
        // `--force-share`: snapshots are most often listed while the guest that
        // owns the disk is running, and the image is write-locked then.
        let result = try run(["info", "--output=json", "--force-share", url.path])
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.inspectionFailed(path: url.path, detail: result.output)
        }
        let entries = object["snapshots"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let seconds = (entry["date-sec"] as? NSNumber)?.doubleValue ?? 0
            let nanoseconds = (entry["date-nsec"] as? NSNumber)?.doubleValue ?? 0
            let clockNanoseconds = (entry["vm-clock-nsec"] as? NSNumber)?.doubleValue
            return SnapshotHandle(
                tag: name,
                createdAt: Date(timeIntervalSince1970: seconds + nanoseconds / 1_000_000_000),
                vmStateSizeBytes: (entry["vm-state-size"] as? NSNumber)?.uint64Value,
                guestUptime: clockNanoseconds.map { .seconds($0 / 1_000_000_000) }
            )
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    /// Deletes a disk. Used by factory reset, never implicitly.
    public func delete(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        MultiemuLog.storage.info("Deleted disk \(url.lastPathComponent, privacy: .public)")
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: toolURL.path) else {
            throw Failure.toolNotFound
        }
        let process = Process()
        process.executableURL = toolURL
        // Arguments are passed as an array; no shell is involved, so paths with
        // spaces need no escaping and nothing can be injected through them.
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
