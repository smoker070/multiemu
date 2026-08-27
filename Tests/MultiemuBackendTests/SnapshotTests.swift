import Foundation
import Testing
@testable import MultiemuBackend

@Suite("Snapshots")
struct SnapshotTests {

    @Test("Ordinary tags are accepted")
    func validTags() {
        for tag in ["checkpoint", "before upgrade", "run-1", "v1.2_final", "Android 14 booted"] {
            #expect(SnapshotHandle.problems(forTag: tag).isEmpty, "\(tag) should be valid")
        }
    }

    @Test("Tags that would break the image are refused")
    func invalidTags() {
        // Tags become identifiers inside a qcow2 image, so they are constrained
        // rather than free text.
        #expect(!SnapshotHandle.problems(forTag: "").isEmpty)
        #expect(!SnapshotHandle.problems(forTag: String(repeating: "x", count: 200)).isEmpty)
        for tag in ["with/slash", "semi;colon", "quote\"mark", "new\nline", "dollar$sign"] {
            #expect(!SnapshotHandle.problems(forTag: tag).isEmpty, "\(tag) should be refused")
        }
    }

    @Test("A handle round-trips through JSON, including the optional fields")
    func codableRoundTrip() throws {
        let original = SnapshotHandle(
            tag: "checkpoint",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            vmStateSizeBytes: 192_837_465,
            guestUptime: .seconds(42.5)
        )
        let decoded = try JSONDecoder().decode(SnapshotHandle.self, from: try JSONEncoder().encode(original))
        #expect(decoded.tag == original.tag)
        #expect(decoded.vmStateSizeBytes == original.vmStateSizeBytes)
        #expect(decoded.guestUptime == original.guestUptime)
    }

    @Test("A handle with no reported size still encodes")
    func optionalFields() throws {
        let original = SnapshotHandle(tag: "bare")
        let decoded = try JSONDecoder().decode(SnapshotHandle.self, from: try JSONEncoder().encode(original))
        #expect(decoded.vmStateSizeBytes == nil)
        #expect(decoded.guestUptime == nil)
    }
}
