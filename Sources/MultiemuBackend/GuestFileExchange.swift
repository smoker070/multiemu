import Foundation
import MultiemuADB

/// Moves files between the host and a guest over ADB, through `SharedFolder`.
///
/// **Why not a mounted share.** Milestone 14 established, and then re-verified
/// after an earlier claim of this shape turned out to be wrong, that the two
/// sides have no filesystem in common: QEMU on macOS offers only
/// `virtio-9p-pci`, and this Android image has `virtiofs` but neither `9p.ko`
/// nor `9pnet_virtio.ko`, so nothing can mount. ADB is the transport that does
/// exist. Google's emulator carries files the same way for the same reason.
///
/// **What changes and what does not.** A copy is not a mount: files are moved
/// on request rather than appearing in a directory, and a change on one side is
/// not visible on the other until it is sent. What does not change is the
/// confinement — every host path still goes through `SharedFolder`, so a guest
/// naming `../../.ssh/id_rsa` is refused here exactly as it would have been
/// over 9p. The transport moved; the boundary did not.
///
/// Blocking. Run it off the cooperative thread pool.
public struct GuestFileExchange: Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case notAFile(String)
        case guestPathNotAbsolute(String)
        case tooLarge(bytes: Int, limit: Int)
        case shareIsReadOnly(String)

        public var description: String {
            switch self {
            case let .notAFile(path): return "\(path) is not a regular file."
            case let .guestPathNotAbsolute(path):
                return "A guest destination must be absolute; got `\(path)`."
            case let .tooLarge(bytes, limit):
                return "\(bytes) bytes exceeds the \(limit)-byte limit for one transfer."
            case let .shareIsReadOnly(tag):
                return "The share `\(tag)` is read-only, so nothing may be written into it."
            }
        }
    }

    /// A ceiling on one transfer, so a mistake cannot pull a disk image into
    /// memory. Not a policy about what may be shared.
    public static let transferLimit = 2 * 1024 * 1024 * 1024

    public let share: SharedFolder
    public let device: ADBDevice

    public init(share: SharedFolder, device: ADBDevice) {
        self.share = share
        self.device = device
    }

    /// Sends a file the host chose into the guest.
    ///
    /// The host path is validated as a host path — the risk in this direction
    /// is handing the guest something the user did not mean to share — and the
    /// guest destination must be absolute.
    @discardableResult
    public func send(hostFile url: URL, toGuestPath guestPath: String,
                     mode: UInt32 = 0o644) throws -> Int {
        let resolved = try SharedFolder.validateHostPath(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw Failure.notAFile(resolved.path)
        }
        guard guestPath.hasPrefix("/") else { throw Failure.guestPathNotAbsolute(guestPath) }

        let data = try Data(contentsOf: resolved)
        guard data.count <= Self.transferLimit else {
            throw Failure.tooLarge(bytes: data.count, limit: Self.transferLimit)
        }
        return try device.push(data, to: guestPath, mode: mode)
    }

    /// Brings a guest file back, into the share and nowhere else.
    ///
    /// `nameInShare` is the dangerous parameter: it is the one a guest, or a
    /// listing taken from a guest, could influence. It is resolved through
    /// `SharedFolder`, which refuses absolute paths, traversal however spelled,
    /// symlinks that leave the share, and names carrying a NUL byte.
    @discardableResult
    public func receive(guestPath: String, intoShareAs nameInShare: String) throws -> URL {
        guard guestPath.hasPrefix("/") else { throw Failure.guestPathNotAbsolute(guestPath) }
        guard !share.isReadOnly else { throw Failure.shareIsReadOnly(share.mountTag) }

        // Resolved before the transfer: a name that cannot be written to is
        // worth discovering before pulling a gigabyte across.
        let destination = try share.resolve(guestPath: nameInShare)
        let data = try device.pull(guestPath, sizeLimit: Self.transferLimit)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
        return destination
    }

    /// Whether the guest has the path, without transferring it.
    public func guestHas(_ guestPath: String) throws -> Bool {
        try device.stat(guestPath).exists
    }
}
