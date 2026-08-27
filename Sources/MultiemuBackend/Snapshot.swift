import Foundation
import MultiemuSupport

/// A saved machine state.
///
/// A snapshot captures RAM as well as disk, so restoring one returns the guest
/// to the exact instant it was taken — which is what makes it useful for
/// Android bring-up: a booted state can be reached in seconds instead of
/// waiting out a full cold boot on every iteration.
public struct SnapshotHandle: Sendable, Equatable, Codable {
    /// Identifier within the disk image. Unique per device.
    public var tag: String
    public var createdAt: Date
    /// Size of the saved machine state, when the backend reports it.
    public var vmStateSizeBytes: UInt64?
    /// Guest uptime at the moment of capture, when reported.
    public var guestUptime: Duration?

    public init(
        tag: String,
        createdAt: Date = Date(),
        vmStateSizeBytes: UInt64? = nil,
        guestUptime: Duration? = nil
    ) {
        self.tag = tag
        self.createdAt = createdAt
        self.vmStateSizeBytes = vmStateSizeBytes
        self.guestUptime = guestUptime
    }

    /// Tags become identifiers inside a qcow2 image, so they are constrained
    /// rather than free text.
    public static func problems(forTag tag: String) -> [String] {
        var problems: [String] = []
        if tag.isEmpty { problems.append("A snapshot tag cannot be empty.") }
        if tag.count > 128 { problems.append("A snapshot tag cannot exceed 128 characters.") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        if tag.rangeOfCharacter(from: allowed.inverted) != nil {
            problems.append("A snapshot tag may contain only letters, digits, spaces, and - _ . characters.")
        }
        return problems
    }
}
