import Foundation
import MultiemuSupport

/// A host directory offered to a guest.
///
/// This is a security boundary, and it is written as one. A guest is untrusted
/// code: anything it sends is data, never a path to act on. The rules here are
/// therefore not conveniences —
///
/// * a share is one explicitly chosen directory, and nothing outside it is
///   reachable however the guest asks;
/// * a guest-supplied path is resolved **within** the share or rejected, and is
///   never resolved against the host filesystem first;
/// * nothing supplied by a guest is ever executed.
///
/// The transport is a separate question. Whether files reach the guest over
/// 9p, virtiofs or a push protocol, every host path passes through here.
public struct SharedFolder: Sendable, Equatable, Codable {

    /// The directory the user chose, fully resolved.
    public let hostDirectory: URL
    /// The name the guest mounts it under.
    public let mountTag: String
    /// Read-only unless the user asked otherwise. A guest that can write to a
    /// host directory can plant anything in it.
    public let isReadOnly: Bool

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notADirectory(path: String)
        case unreadable(path: String)
        case invalidMountTag(String)
        case escapesShare(requested: String)
        case absolutePathFromGuest(requested: String)
        case emptyPath
        case unsupportedCharacters(requested: String)

        public var description: String {
            switch self {
            case let .notADirectory(path):
                return "\(path) is not a directory."
            case let .unreadable(path):
                return "\(path) cannot be read."
            case let .invalidMountTag(tag):
                return """
                    "\(tag)" is not a usable mount name. Use 1–31 characters from \
                    A–Z, a–z, 0–9, dot, dash or underscore.
                    """
            case let .escapesShare(requested):
                return "\"\(requested)\" points outside the shared folder."
            case let .absolutePathFromGuest(requested):
                return "\"\(requested)\" is an absolute path; the guest may only name paths inside the share."
            case .emptyPath:
                return "An empty path was requested."
            case let .unsupportedCharacters(requested):
                return "\"\(requested)\" contains characters that are not allowed in a path."
            }
        }
    }

    /// Mount tags travel to the guest and are used to name a device, so they are
    /// restricted to a conservative set rather than sanitised after the fact.
    public static let maximumMountTagLength = 31

    public init(hostDirectory: URL, mountTag: String, isReadOnly: Bool = true) throws {
        let resolved = hostDirectory.resolvingSymlinksInPath().standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw Failure.notADirectory(path: resolved.path)
        }
        guard isDirectory.boolValue else { throw Failure.notADirectory(path: resolved.path) }
        guard FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw Failure.unreadable(path: resolved.path)
        }
        guard Self.isValidMountTag(mountTag) else { throw Failure.invalidMountTag(mountTag) }

        self.hostDirectory = resolved
        self.mountTag = mountTag
        self.isReadOnly = isReadOnly
    }

    public static func isValidMountTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.count <= maximumMountTagLength else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return tag.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Resolving what a guest asks for

    /// Turns a path a **guest** supplied into a host URL inside this share, or
    /// refuses.
    ///
    /// Every rule here exists because of a specific way out of a directory:
    ///
    /// * an absolute path ignores the share entirely;
    /// * `..` walks upward, including when spelled across several components;
    /// * a symlink inside the share can point anywhere, so the *result* is
    ///   re-resolved and re-checked rather than the input being trusted;
    /// * a NUL byte truncates the path at the system-call boundary, so a name
    ///   that passed inspection is not the name that gets opened.
    ///
    /// The check is on the resolved result, not on the spelling of the input:
    /// pattern-matching for ".." is the version of this that gets bypassed.
    public func resolve(guestPath: String) throws -> URL {
        guard !guestPath.isEmpty else { throw Failure.emptyPath }
        guard !guestPath.contains("\0") else {
            throw Failure.unsupportedCharacters(requested: guestPath)
        }
        guard !guestPath.hasPrefix("/") else {
            throw Failure.absolutePathFromGuest(requested: guestPath)
        }
        // A Windows-style root or drive letter is not a path this host should
        // interpret at all.
        guard !guestPath.contains("\\") else {
            throw Failure.unsupportedCharacters(requested: guestPath)
        }

        // Walked one component at a time, resolving each link as it is reached
        // and checking containment after every step.
        //
        // The obvious implementation — append the whole path, call
        // `resolvingSymlinksInPath()`, check the result — has a hole that this
        // project measured rather than reasoned about. Foundation resolves a
        // symlinked *intermediate* component only when the final component
        // exists. So `link/existing.txt` is resolved and caught, while
        // `link/not-yet.txt` comes back unchanged and looks like it is inside
        // the share. The second is the shape that matters: it is what a write
        // looks like, and the write itself follows the link.
        //
        // Checking at every step also closes `link/..`, where a textual
        // collapse would step back into the share while the kernel would step
        // into the link target's parent.
        var current = hostDirectory.resolvingSymlinksInPath().standardizedFileURL
        for piece in guestPath.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                current = current.deletingLastPathComponent().standardizedFileURL
            default:
                current = current.appendingPathComponent(String(piece))
                current = Self.followingLink(at: current)
            }
            guard contains(current) else { throw Failure.escapesShare(requested: guestPath) }
        }

        guard contains(current) else { throw Failure.escapesShare(requested: guestPath) }
        return current
    }

    /// Resolves one component if it is a link, including a dangling one.
    ///
    /// A dangling link has to be followed too. `fileExists` says no for one,
    /// and `resolvingSymlinksInPath()` leaves it alone — which would let a link
    /// to a path that does not exist yet pass as though it were an ordinary
    /// name, and that is precisely the case a write creates.
    private static func followingLink(at url: URL) -> URL {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeSymbolicLink,
              let destination = try? manager.destinationOfSymbolicLink(atPath: url.path)
        else {
            // Not a link. Resolve anyway when it exists, so a share reached
            // through a link elsewhere still compares against real paths.
            return manager.fileExists(atPath: url.path)
                ? url.resolvingSymlinksInPath().standardizedFileURL
                : url.standardizedFileURL
        }

        let target = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : url.deletingLastPathComponent().appendingPathComponent(destination)
        let standardized = target.standardizedFileURL
        // Follow a chain as far as it exists; a chain that dangles part way is
        // left where it stops, and the containment check decides.
        return manager.fileExists(atPath: standardized.path)
            ? standardized.resolvingSymlinksInPath().standardizedFileURL
            : standardized
    }

    /// Whether a fully resolved URL lies inside this share.
    ///
    /// Compared component-wise rather than by string prefix: `/tmp/share-evil`
    /// has `/tmp/share` as a string prefix but is a different directory.
    public func contains(_ url: URL) -> Bool {
        let base = hostDirectory.standardizedFileURL.pathComponents
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard candidate.count >= base.count else { return false }
        return Array(candidate.prefix(base.count)) == base
    }

    /// Checks a path the **host** supplied — a drag-and-drop, or a file picked
    /// in an open panel — before it is offered to a guest.
    ///
    /// Separate from `resolve(guestPath:)` because the threat is the other way
    /// round: here the risk is handing a guest something the user did not mean
    /// to share.
    public static func validateHostPath(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard !resolved.path.isEmpty else { throw Failure.emptyPath }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw Failure.unreadable(path: resolved.path)
        }
        guard FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw Failure.unreadable(path: resolved.path)
        }
        return resolved
    }

    /// Problems that should be shown before a device starts.
    public func problems() -> [String] {
        var problems: [String] = []
        if !isReadOnly {
            problems.append("""
                "\(mountTag)" is writable by the guest. Anything running in the guest can \
                change files in \(hostDirectory.path).
                """)
        }
        return problems
    }
}
