import Foundation
import MultiemuADB
import Testing
@testable import MultiemuBackend

@Suite("File exchange keeps the share's boundary")
struct GuestFileExchangeTests {

    /// A device on a port nothing is listening on.
    ///
    /// Every test here asserts a refusal that must happen *before* any
    /// connection is attempted. Pointing at a dead port is what proves that:
    /// if a check were ever moved after the transfer, these tests would fail
    /// with a connection error instead of the named one.
    static let unreachableDevice = ADBDevice(port: 1, timeout: 1)

    static func makeShare(readOnly: Bool = false) throws -> (SharedFolder, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiemu-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try SharedFolder(hostDirectory: root, mountTag: "share", isReadOnly: readOnly), root)
    }

    @Test("A guest-named file cannot be written outside the share")
    func traversalIsRefused() throws {
        let (share, root) = try Self.makeShare()
        defer { try? FileManager.default.removeItem(at: root) }
        let exchange = GuestFileExchange(share: share, device: Self.unreachableDevice)

        for name in ["../escaped.txt", "../../etc/passwd", "a/../../escaped.txt"] {
            #expect(throws: SharedFolder.Failure.self) {
                try exchange.receive(guestPath: "/data/local/tmp/x", intoShareAs: name)
            }
        }
    }

    @Test("An absolute host name from the guest is refused")
    func absoluteNameIsRefused() throws {
        let (share, root) = try Self.makeShare()
        defer { try? FileManager.default.removeItem(at: root) }
        let exchange = GuestFileExchange(share: share, device: Self.unreachableDevice)
        #expect(throws: SharedFolder.Failure.self) {
            try exchange.receive(guestPath: "/data/local/tmp/x", intoShareAs: "/etc/hosts")
        }
    }

    @Test("A name carrying a NUL byte is refused before it reaches a syscall")
    func nulByteIsRefused() throws {
        let (share, root) = try Self.makeShare()
        defer { try? FileManager.default.removeItem(at: root) }
        let exchange = GuestFileExchange(share: share, device: Self.unreachableDevice)
        // A NUL truncates the path at the system-call boundary, so the name
        // that was inspected is not the name that would be opened.
        #expect(throws: SharedFolder.Failure.self) {
            try exchange.receive(guestPath: "/data/local/tmp/x", intoShareAs: "ok.txt\0/../../evil")
        }
    }

    @Test("A symlink inside the share pointing out of it does not become a way out")
    func symlinkOutOfShareIsRefused() throws {
        let (share, root) = try Self.makeShare()
        defer { try? FileManager.default.removeItem(at: root) }
        let escape = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: escape, withDestinationURL: URL(fileURLWithPath: "/tmp"))

        let exchange = GuestFileExchange(share: share, device: Self.unreachableDevice)
        #expect(throws: SharedFolder.Failure.self) {
            try exchange.receive(guestPath: "/data/local/tmp/x", intoShareAs: "escape/planted.txt")
        }
    }

    @Test("A read-only share refuses to receive anything at all")
    func readOnlyShareRefusesWrites() throws {
        let (share, root) = try Self.makeShare(readOnly: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exchange = GuestFileExchange(share: share, device: Self.unreachableDevice)
        #expect(throws: GuestFileExchange.Failure.self) {
            try exchange.receive(guestPath: "/data/local/tmp/x", intoShareAs: "fine.txt")
        }
    }

    @Test("A relative guest path is refused in both directions")
    func guestPathsMustBeAbsolute() throws {
        let (share, root) = try Self.makeShare()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload.bin")
        try Data("x".utf8).write(to: file)

        let exchange = GuestFileExchange(share: share, device: Self.unreachableDevice)
        #expect(throws: GuestFileExchange.Failure.self) {
            try exchange.send(hostFile: file, toGuestPath: "tmp/relative")
        }
        #expect(throws: GuestFileExchange.Failure.self) {
            try exchange.receive(guestPath: "relative/path", intoShareAs: "fine.txt")
        }
    }

    @Test("A directory is not sent as though it were a file")
    func directoriesAreRefused() throws {
        let (share, root) = try Self.makeShare()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        let exchange = GuestFileExchange(share: share, device: Self.unreachableDevice)
        #expect(throws: GuestFileExchange.Failure.self) {
            try exchange.send(hostFile: inner, toGuestPath: "/data/local/tmp/folder")
        }
    }

    @Test("A host file that does not exist is refused as a host-path problem")
    func missingHostFileIsRefused() throws {
        let (share, root) = try Self.makeShare()
        defer { try? FileManager.default.removeItem(at: root) }
        let exchange = GuestFileExchange(share: share, device: Self.unreachableDevice)
        #expect(throws: SharedFolder.Failure.self) {
            try exchange.send(hostFile: root.appendingPathComponent("absent.bin"),
                              toGuestPath: "/data/local/tmp/absent.bin")
        }
    }

    @Test("A name that merely shares a prefix with the share is still outside it")
    func siblingPrefixIsRefused() throws {
        let (share, root) = try Self.makeShare()
        defer { try? FileManager.default.removeItem(at: root) }
        // `/tmp/share-evil` has `/tmp/share` as a string prefix and is a
        // different directory; the comparison is component-wise for this.
        let sibling = URL(fileURLWithPath: root.path + "-evil")
        #expect(share.contains(sibling) == false)
    }
}
