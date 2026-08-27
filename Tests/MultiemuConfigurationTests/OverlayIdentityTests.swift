import Foundation
import Testing
import MultiemuDisks
import MultiemuSupport

/// An overlay names its backing file, and adopting the wrong one boots the
/// wrong disk. These check that the wrong one is refused rather than reused.
@Suite("Overlay identity", .enabled(if: VirtualDiskManager.locateDevelopmentTool() != nil))
struct OverlayIdentityTests {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiemu-overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("An existing overlay over the requested base is reused")
    func matchingOverlayIsReused() throws {
        let manager = try #require(VirtualDiskManager.locateDevelopmentTool())
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let base = root.appendingPathComponent("base.img")
        try manager.create(at: base, format: .raw, sizeBytes: 64 * ByteCount.miB)
        let overlay = root.appendingPathComponent("overlay.qcow2")

        try manager.ensureOverlay(at: overlay, backedBy: base, baseFormat: .raw)
        // Second call must adopt the same file rather than fail or rebuild.
        try manager.ensureOverlay(at: overlay, backedBy: base, baseFormat: .raw)
        #expect(FileManager.default.fileExists(atPath: overlay.path))
        #expect(try manager.backingFile(at: overlay)?.hasSuffix("base.img") == true)
    }

    @Test("An overlay backed by a different image is refused, not adopted")
    func mismatchedOverlayIsRefused() throws {
        // Overlay names are derived from the source's filename, so two
        // different bases can want the same overlay name. Adopting blindly is
        // how a device silently boots somebody else's disk.
        let manager = try #require(VirtualDiskManager.locateDevelopmentTool())
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.img")
        let second = root.appendingPathComponent("second.img")
        try manager.create(at: first, format: .raw, sizeBytes: 64 * ByteCount.miB)
        try manager.create(at: second, format: .raw, sizeBytes: 64 * ByteCount.miB)

        let overlay = root.appendingPathComponent("overlay.qcow2")
        try manager.ensureOverlay(at: overlay, backedBy: first, baseFormat: .raw)

        #expect(throws: VirtualDiskManager.Failure.self) {
            try manager.ensureOverlay(at: overlay, backedBy: second, baseFormat: .raw)
        }
    }

    @Test("A plain disk sitting where an overlay belongs is refused")
    func nonOverlayIsRefused() throws {
        // It has no backing file at all, so nothing about it matches.
        let manager = try #require(VirtualDiskManager.locateDevelopmentTool())
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let base = root.appendingPathComponent("base.img")
        try manager.create(at: base, format: .raw, sizeBytes: 64 * ByteCount.miB)

        let impostor = root.appendingPathComponent("overlay.qcow2")
        try manager.create(at: impostor, format: .qcow2, sizeBytes: 64 * ByteCount.miB)

        #expect(throws: VirtualDiskManager.Failure.self) {
            try manager.ensureOverlay(at: impostor, backedBy: base, baseFormat: .raw)
        }
    }
}
