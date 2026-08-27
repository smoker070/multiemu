import Foundation

/// Builds real ZIP archives so the APK checks are tested against the format
/// rather than against a mock of it.
///
/// Stored (uncompressed) entries only, which is all that is needed: the
/// inspector reads the central directory for names and never decompresses.
enum ZipFixture {

    static func archive(entries: [(name: String, contents: Data)]) -> Data {
        var output = Data()
        var directory = Data()

        func append16(_ value: Int, to data: inout Data) {
            withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        func append32(_ value: UInt32, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        for entry in entries {
            let offset = UInt32(output.count)
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.contents)
            let size = UInt32(entry.contents.count)

            append32(0x0403_4B50, to: &output)
            append16(20, to: &output)      // version needed
            append16(0, to: &output)       // flags
            append16(0, to: &output)       // stored
            append16(0, to: &output)       // time
            append16(0, to: &output)       // date
            append32(crc, to: &output)
            append32(size, to: &output)
            append32(size, to: &output)
            append16(name.count, to: &output)
            append16(0, to: &output)       // extra
            output.append(name)
            output.append(entry.contents)

            append32(0x0201_4B50, to: &directory)
            append16(20, to: &directory)   // version made by
            append16(20, to: &directory)   // version needed
            append16(0, to: &directory)    // flags
            append16(0, to: &directory)    // stored
            append16(0, to: &directory)    // time
            append16(0, to: &directory)    // date
            append32(crc, to: &directory)
            append32(size, to: &directory)
            append32(size, to: &directory)
            append16(name.count, to: &directory)
            append16(0, to: &directory)    // extra
            append16(0, to: &directory)    // comment
            append16(0, to: &directory)    // disk
            append16(0, to: &directory)    // internal attributes
            append32(0, to: &directory)    // external attributes
            append32(offset, to: &directory)
            directory.append(name)
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)
        append32(0x0605_4B50, to: &output)
        append16(0, to: &output)
        append16(0, to: &output)
        append16(entries.count, to: &output)
        append16(entries.count, to: &output)
        append32(UInt32(directory.count), to: &output)
        append32(directoryOffset, to: &output)
        append16(0, to: &output)
        return output
    }

    /// An archive shaped like an APK: a manifest and one other entry.
    static func apk() -> Data {
        archive(entries: [
            (name: "AndroidManifest.xml", contents: Data([0x03, 0x00, 0x08, 0x00])),
            (name: "classes.dex", contents: Data("not a real dex".utf8)),
        ])
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
