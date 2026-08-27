import Foundation
import Testing
@testable import MultiemuBackend
import MultiemuSupport

/// A shared folder is a security boundary, so these tests are written as
/// attempts to get out of it rather than as a demonstration that it works.
@Suite("Shared folder confinement")
struct SharedFolderTests {

    private func makeShare(readOnly: Bool = true) throws -> (share: SharedFolder, root: URL, outside: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-share-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("share", isDirectory: true)
        let outside = base.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: root.appendingPathComponent("ok.txt"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        return (try SharedFolder(hostDirectory: root, mountTag: "share", isReadOnly: readOnly),
                root, outside)
    }

    // MARK: - Getting out

    @Test("A path inside the share resolves")
    func insideResolves() throws {
        let (share, root, _) = try makeShare()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let resolved = try share.resolve(guestPath: "ok.txt")
        #expect(resolved.lastPathComponent == "ok.txt")
        #expect(share.contains(resolved))
    }

    @Test("Walking up out of the share is refused, however it is spelled")
    func traversalIsRefused() throws {
        let (share, root, _) = try makeShare()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        for attempt in [
            "../private/secret.txt",
            "../../etc/passwd",
            "./../../etc/passwd",
            "a/../../private/secret.txt",
            "a/b/c/../../../../private/secret.txt",
            "..",
            "../",
        ] {
            #expect(throws: SharedFolder.Failure.self, "\(attempt) was allowed out") {
                try share.resolve(guestPath: attempt)
            }
        }
    }

    @Test("An absolute path from the guest is refused rather than followed")
    func absolutePathsAreRefused() throws {
        let (share, root, _) = try makeShare()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        for attempt in ["/etc/passwd", "/", "//etc/passwd", "/tmp"] {
            #expect(throws: SharedFolder.Failure.self, "\(attempt) was followed") {
                try share.resolve(guestPath: attempt)
            }
        }
    }

    @Test("A symlink inside the share cannot be used to reach outside it")
    func symlinkEscapeIsRefused() throws {
        let (share, root, outside) = try makeShare()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        // The dangerous case: the link lives inside the share, so the *input*
        // looks entirely innocent. Only re-resolving the result catches it.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        #expect(throws: SharedFolder.Failure.self) {
            try share.resolve(guestPath: "escape/secret.txt")
        }
        #expect(throws: SharedFolder.Failure.self) {
            try share.resolve(guestPath: "escape")
        }
    }

    @Test("A symlink to a file that does not exist yet is still an escape")
    func danglingSymlinkEscapeIsRefused() throws {
        let (share, root, outside) = try makeShare(readOnly: false)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        // The case the suite above missed for as long as it existed. Its
        // symlink test named `escape/secret.txt`, and that file exists, so
        // Foundation resolved the whole path and the escape was caught.
        // Foundation resolves a symlinked intermediate component *only* when
        // the final component exists — so a name for a file that is not there
        // yet came back unchanged and looked like it was inside the share.
        //
        // That is the shape a write takes, and the write follows the link.
        // Measured, not reasoned about: `resolvingSymlinksInPath()` returned
        // `<share>/escape/planted.txt` verbatim.
        for name in ["escape/planted.txt", "escape/nested/deeper.txt"] {
            #expect(throws: SharedFolder.Failure.self) {
                try share.resolve(guestPath: name)
            }
        }
    }

    @Test("A symlink that dangles entirely is refused rather than treated as a name")
    func brokenSymlinkIsRefused() throws {
        let (share, root, outside) = try makeShare(readOnly: false)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        // A link whose target does not exist at all. `fileExists` says no for
        // one of these and `resolvingSymlinksInPath()` leaves it alone, so it
        // has to be followed explicitly or it passes as an ordinary name.
        let target = outside.appendingPathComponent("not-created-yet")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("broken"), withDestinationURL: target)

        #expect(throws: SharedFolder.Failure.self) {
            try share.resolve(guestPath: "broken")
        }
        #expect(throws: SharedFolder.Failure.self) {
            try share.resolve(guestPath: "broken/child.txt")
        }
    }

    @Test("Stepping up out of a symlinked directory does not step back into the share")
    func parentOfSymlinkIsRefused() throws {
        let (share, root, outside) = try makeShare(readOnly: false)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        // Collapsing `escape/..` textually gives the share back, which looks
        // safe. The kernel gives the link target's parent, which is not.
        #expect(throws: SharedFolder.Failure.self) {
            try share.resolve(guestPath: "escape/../secret-sibling.txt")
        }
    }

    @Test("A sibling directory sharing a name prefix is not inside the share")
    func siblingPrefixIsNotContained() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-prefix-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("share", isDirectory: true)
        // "share-evil" has "share" as a *string* prefix but is a different
        // directory. Comparing paths as strings would let it through.
        let sibling = base.appendingPathComponent("share-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let share = try SharedFolder(hostDirectory: root, mountTag: "share")
        #expect(!share.contains(sibling))
        #expect(!share.contains(sibling.appendingPathComponent("file.txt")))
        #expect(share.contains(root.appendingPathComponent("file.txt")))
    }

    @Test("A NUL byte is refused, because it truncates the path at the syscall")
    func nulByteIsRefused() throws {
        let (share, root, _) = try makeShare()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        // The name that passes inspection would not be the name that is opened.
        #expect(throws: SharedFolder.Failure.self) {
            try share.resolve(guestPath: "ok.txt\0/../../etc/passwd")
        }
        #expect(throws: SharedFolder.Failure.self) { try share.resolve(guestPath: "\0") }
    }

    @Test("An empty path and a backslash path are refused")
    func malformedPathsAreRefused() throws {
        let (share, root, _) = try makeShare()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        #expect(throws: SharedFolder.Failure.self) { try share.resolve(guestPath: "") }
        #expect(throws: SharedFolder.Failure.self) { try share.resolve(guestPath: "..\\..\\secret") }
        #expect(throws: SharedFolder.Failure.self) { try share.resolve(guestPath: "C:\\Windows") }
    }

    @Test("A path that does not exist yet still has to be inside the share")
    func nonexistentPathsAreStillConfined() throws {
        let (share, root, _) = try makeShare()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        // Confinement cannot depend on the file existing, or a guest could name
        // somewhere outside and have the check pass because nothing is there.
        let resolved = try share.resolve(guestPath: "not/created/yet.txt")
        #expect(share.contains(resolved))
        #expect(throws: SharedFolder.Failure.self) {
            try share.resolve(guestPath: "../not/created/yet.txt")
        }
    }

    // MARK: - Constructing one

    @Test("A share must be an existing, readable directory")
    func shareMustBeADirectory() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let file = base.appendingPathComponent("a-file.txt")
        try Data("x".utf8).write(to: file)

        #expect(throws: SharedFolder.Failure.self) {
            try SharedFolder(hostDirectory: file, mountTag: "share")
        }
        #expect(throws: SharedFolder.Failure.self) {
            try SharedFolder(hostDirectory: base.appendingPathComponent("missing"), mountTag: "share")
        }
    }

    @Test("Mount tags are restricted rather than sanitised")
    func mountTagsAreRestricted() {
        #expect(SharedFolder.isValidMountTag("share"))
        #expect(SharedFolder.isValidMountTag("my-share_1.0"))
        #expect(!SharedFolder.isValidMountTag(""))
        #expect(!SharedFolder.isValidMountTag("has space"))
        #expect(!SharedFolder.isValidMountTag("has/slash"))
        #expect(!SharedFolder.isValidMountTag("has,comma"))   // would split a QEMU option
        #expect(!SharedFolder.isValidMountTag(String(repeating: "a", count: 32)))
        #expect(SharedFolder.isValidMountTag(String(repeating: "a", count: 31)))
    }

    @Test("A writable share says so, because it is the dangerous configuration")
    func writableShareWarns() throws {
        let (readOnly, root, _) = try makeShare(readOnly: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(readOnly.problems().isEmpty)

        let writable = try SharedFolder(hostDirectory: root, mountTag: "share", isReadOnly: false)
        #expect(writable.problems().contains { $0.contains("writable by the guest") })
    }

    @Test("Read-only is the default")
    func readOnlyByDefault() throws {
        let (share, root, _) = try makeShare()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(share.isReadOnly)
    }

    // MARK: - Host-supplied paths

    @Test("A host path is resolved and checked before it is offered to a guest")
    func hostPathsAreValidated() throws {
        let (_, root, _) = try makeShare()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let file = root.appendingPathComponent("ok.txt")
        #expect(try SharedFolder.validateHostPath(file).lastPathComponent == "ok.txt")
        #expect(throws: SharedFolder.Failure.self) {
            try SharedFolder.validateHostPath(root.appendingPathComponent("missing.txt"))
        }
    }
}
