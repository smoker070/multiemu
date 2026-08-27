import Foundation

/// A GPT GUID, stored in the on-disk mixed-endian byte order.
///
/// GPT stores the first three fields little-endian and the last two big-endian.
/// Getting that wrong produces a disk whose partition types look like garbage to
/// every tool, so the conversion lives in one place with the layout spelled out.
public struct GUID: Sendable, Equatable {
    public var bytes: [UInt8]   // 16 bytes, on-disk order

    public init?(_ text: String) {
        let hex = text.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { return nil }
        var raw = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            raw.append(byte)
            index = next
        }
        // time_low (4), time_mid (2), time_hi_and_version (2) are little-endian
        // on disk; clock_seq (2) and node (6) are big-endian.
        bytes = [
            raw[3], raw[2], raw[1], raw[0],
            raw[5], raw[4],
            raw[7], raw[6],
            raw[8], raw[9],
            raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        ]
    }

    public init(onDiskBytes: [UInt8]) {
        precondition(onDiskBytes.count == 16)
        bytes = onDiskBytes
    }

    /// Canonical text form, converting back out of on-disk order.
    public var description: String {
        let b = bytes
        func hex(_ values: [UInt8]) -> String {
            values.map { String(format: "%02x", $0) }.joined()
        }
        return [
            hex([b[3], b[2], b[1], b[0]]),
            hex([b[5], b[4]]),
            hex([b[7], b[6]]),
            hex([b[8], b[9]]),
            hex(Array(b[10..<16])),
        ].joined(separator: "-")
    }

    /// Deterministic GUID derived from a name.
    ///
    /// Virtual devices must produce identical disks on every run so that a
    /// snapshot or a checksum means something; a random GUID would make the
    /// same inputs yield a different disk each time.
    public static func deterministic(from seed: String) -> GUID {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var bytes = [UInt8]()
        for round in 0..<2 {
            for byte in ("\(seed)#\(round)").utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            withUnsafeBytes(of: hash.littleEndian) { bytes.append(contentsOf: $0) }
        }
        // Set version 4 and the RFC 4122 variant so the value is a well-formed
        // GUID rather than arbitrary bytes.
        bytes[7] = (bytes[7] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return GUID(onDiskBytes: bytes)
    }
}

/// CRC-32 (IEEE 802.3, reflected), as required by the GPT specification.
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    static func compute(_ data: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
