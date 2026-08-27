import Compression
import Foundation

/// Reads the file names out of an Android ramdisk.
///
/// Only the names: the point is to ask the image what board it is and which
/// `fstab` variants it carries, and both answers are file names.
///
/// **Why not scan the compressed bytes.** That was tried. A raw search of the
/// compressed ramdisk found `ueventd.cutf_cvm.rc` and a *truncated*
/// `fstab.cf.ext4.c`, and missed the f2fs variants entirely — because parts of
/// a compressed stream happen to survive as plain text and parts do not. A
/// detector built on that would have chosen the ext4 fstab for an image whose
/// userdata is provably f2fs, and the guest would have hung at first-stage
/// mount with nothing to explain it.
public enum AndroidRamdisk {

    /// LZ4 "legacy" frame magic, little-endian on disk as `02 21 4c 18`.
    static let lz4LegacyMagic: UInt32 = 0x184C_2102
    /// The uncompressed size of one legacy block is fixed at 8 MiB.
    static let lz4LegacyBlockSize = 8 * 1024 * 1024
    /// cpio "newc" header magic.
    static let cpioMagic = Data("070701".utf8)

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case undecodable(String)

        public var description: String {
            switch self {
            case let .unreadable(path): return "Could not read the ramdisk at \(path)."
            case let .undecodable(detail): return "Could not decompress the ramdisk: \(detail)"
            }
        }
    }

    /// Decompresses a ramdisk, if it is compressed at all.
    ///
    /// Handles **concatenated frames**, which is not a nicety: this project
    /// writes the vendor ramdisk followed by the generic one, so a real
    /// ramdisk here contains two LZ4 frames back to back. Stopping at the
    /// first would silently return half the tree — and the half that is
    /// missing is the one carrying the fstabs.
    public static func decompress(_ data: Data) throws -> Data {
        if data.starts(with: cpioMagic) { return data }

        var output = Data()
        var cursor = data.startIndex

        func word(at index: Data.Index) -> UInt32? {
            guard data.distance(from: index, to: data.endIndex) >= 4 else { return nil }
            return data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(
                    fromByteOffset: data.distance(from: data.startIndex, to: index),
                    as: UInt32.self))
            }
        }

        while cursor < data.endIndex {
            guard let magic = word(at: cursor), magic == lz4LegacyMagic else {
                // Not a frame we know. If nothing has been decoded yet the
                // caller gave us something unexpected; say so rather than
                // returning a plausible-looking empty tree.
                if output.isEmpty {
                    throw Failure.undecodable(
                        "expected an LZ4 legacy frame or a cpio archive; "
                            + "the first bytes are \(data.prefix(4).map { String(format: "%02x", $0) }.joined())")
                }
                break
            }
            cursor = data.index(cursor, offsetBy: 4)

            while cursor < data.endIndex {
                guard let size = word(at: cursor) else { break }
                // The next frame begins where a block size would be.
                if size == lz4LegacyMagic { break }
                guard size > 0, Int(size) <= data.distance(from: cursor, to: data.endIndex) - 4 else { break }
                cursor = data.index(cursor, offsetBy: 4)
                let end = data.index(cursor, offsetBy: Int(size))
                output.append(try decodeLZ4Block(Data(data[cursor..<end])))
                cursor = end
            }
        }
        return output
    }

    private static func decodeLZ4Block(_ block: Data) throws -> Data {
        var destination = [UInt8](repeating: 0, count: lz4LegacyBlockSize)
        let written = block.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            // COMPRESSION_LZ4_RAW: a bare block with no frame header, which is
            // exactly what a legacy frame contains. `compression_decode_buffer`
            // returns the byte count written, or 0 on failure.
            return compression_decode_buffer(
                &destination, lz4LegacyBlockSize, base, block.count, nil, COMPRESSION_LZ4_RAW)
        }
        // `compression_decode_buffer` returns bytes written and **cannot
        // distinguish a too-small destination from corrupt input** — both come
        // back as a number the caller has to interpret. That is safe here only
        // because the legacy format caps an uncompressed block at 8 MiB and the
        // destination is exactly that size, so a short write means bad input
        // and never truncation. If the block ceiling ever changes, this
        // reasoning goes with it.
        guard written > 0 else {
            throw Failure.undecodable("a \(block.count)-byte LZ4 block did not decode")
        }
        return Data(destination[0..<written])
    }

    /// Every entry name in a cpio "newc" archive.
    ///
    /// Parsed rather than pattern-matched. A newc header is 110 ASCII-hex bytes
    /// with the name length at offset 94, so the names are exact — no guessing
    /// where one ends, and no risk of catching a string that happens to live
    /// inside a file's contents.
    public static func cpioEntryNames(_ data: Data) -> [String] {
        var names: [String] = []
        var index = data.startIndex

        func hex(_ start: Data.Index, _ length: Int) -> Int? {
            guard data.distance(from: start, to: data.endIndex) >= length else { return nil }
            let end = data.index(start, offsetBy: length)
            return Int(String(decoding: data[start..<end], as: UTF8.self), radix: 16)
        }

        while data.distance(from: index, to: data.endIndex) >= 110 {
            guard data[index..<data.index(index, offsetBy: 6)].elementsEqual(cpioMagic) else {
                index = data.index(after: index)
                continue
            }
            guard let fileSize = hex(data.index(index, offsetBy: 54), 8),
                  let nameSize = hex(data.index(index, offsetBy: 94), 8),
                  nameSize > 0, nameSize < 4096 else { break }

            let nameStart = data.index(index, offsetBy: 110)
            guard data.distance(from: nameStart, to: data.endIndex) >= nameSize else { break }
            let nameEnd = data.index(nameStart, offsetBy: nameSize)
            let name = String(decoding: data[nameStart..<nameEnd], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            // A trailer ends ITS archive, not the file.
            //
            // This ramdisk is two cpio archives back to back — one per LZ4
            // frame — and stopping here returned 522 of 559 entries while
            // looking entirely successful. The test that let it through
            // asserted only `count > 100`.
            //
            // Note also that `TRAILER!!!` occurs four times in the decompressed
            // stream and only two of those are records: the other two sit in a
            // binary's string table (`070701%040X…TRAILER!!!%c%c%c%c`, toybox's
            // cpio writer). Counting the string rather than walking headers
            // would report four archives.
            if name != "TRAILER!!!", !name.isEmpty { names.append(name) }

            // Header+name and the file body are each padded to a 4-byte boundary.
            func padded(_ value: Int) -> Int { (value + 3) & ~3 }
            let advance = padded(110 + nameSize) + padded(fileSize)
            index = data.index(index, offsetBy: max(advance, 1))
        }
        return names
    }

    /// The entry names of the ramdisk at `url`, decompressing as needed.
    public static func entryNames(at url: URL) throws -> [String] {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw Failure.unreadable(url.path)
        }
        return cpioEntryNames(try decompress(data))
    }
}
