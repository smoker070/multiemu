import Foundation

/// Bounds-checked little-endian reader for binary headers.
///
/// Every field read from an image file goes through this. Android image headers
/// are attacker-influenced input in the threat model — a downloaded image is a
/// kernel that will run with full guest privileges — so a malformed header must
/// produce a named error, never an out-of-bounds read or a silently wrong value.
struct ByteReader {

    enum Failure: Error, Equatable, CustomStringConvertible {
        case outOfBounds(offset: Int, needed: Int, available: Int)

        var description: String {
            switch self {
            case let .outOfBounds(offset, needed, available):
                return "Header truncated: needed \(needed) bytes at offset \(offset) but only \(available) are present."
            }
        }
    }

    private let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var count: Int { data.count }

    mutating func bytes(_ length: Int) throws -> Data {
        guard length >= 0, offset + length <= data.count else {
            throw Failure.outOfBounds(offset: offset, needed: length, available: max(0, data.count - offset))
        }
        let start = data.startIndex + offset
        let slice = data[start..<(start + length)]
        offset += length
        return Data(slice)
    }

    mutating func uint32() throws -> UInt32 {
        let raw = try bytes(4)
        return raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    mutating func uint64() throws -> UInt64 {
        let raw = try bytes(8)
        return raw.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }

    /// Reads a fixed-width, NUL-padded string field.
    mutating func fixedString(_ length: Int) throws -> String {
        let raw = try bytes(length)
        return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }

    mutating func skip(_ length: Int) throws {
        _ = try bytes(length)
    }
}

/// Rounds `value` up to the next multiple of `alignment`.
///
/// Android image layouts are page-aligned: every section starts at a page
/// boundary and is padded to one. Getting this wrong reads the next section's
/// first bytes as the previous section's tail, which produces a kernel that
/// almost works — the worst possible failure mode.
func roundUpToMultiple(_ value: Int, of alignment: Int) -> Int {
    guard alignment > 0 else { return value }
    let remainder = value % alignment
    return remainder == 0 ? value : value + (alignment - remainder)
}
