import Foundation
import MultiemuSupport

/// Android's sparse image container.
///
/// AOSP ships `super.img` — and often `userdata.img` — in this format rather
/// than as a raw filesystem: a header followed by chunks that are either
/// literal data, a repeated fill word, or a run of blocks nobody wrote. It is
/// how a 1.63 GiB download expands to an 8 GiB partition.
///
/// This matters because the container looks like a plausible disk image until
/// something tries to read it. Writing one into a partition raw produced a
/// guest that booted, found its `super` partition, and then reported
/// `[liblp] Logical partition metadata has invalid geometry magic signature` —
/// because it was reading a sparse header where the partition table should be.
///
/// The format is little-endian throughout and documented in AOSP's
/// `system/core/libsparse/sparse_format.h`.
public enum AndroidSparseImage {

    public static let magic: UInt32 = 0xED26_FF3A

    private enum ChunkType: UInt16 {
        case raw = 0xCAC1
        case fill = 0xCAC2
        case dontCare = 0xCAC3
        case crc32 = 0xCAC4
    }

    public struct Header: Sendable, Equatable {
        public var majorVersion: UInt16
        public var minorVersion: UInt16
        public var fileHeaderSize: UInt16
        public var chunkHeaderSize: UInt16
        public var blockSizeBytes: UInt32
        public var totalBlocks: UInt32
        public var totalChunks: UInt32

        /// What the image occupies once expanded. This, not the file's size on
        /// disk, is how large the partition has to be.
        public var expandedSizeBytes: UInt64 {
            UInt64(totalBlocks) * UInt64(blockSizeBytes)
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(path: String)
        case unsupportedVersion(major: UInt16, minor: UInt16)
        case implausibleBlockSize(UInt32)
        case unknownChunkType(UInt16, atChunk: Int)
        case truncated(atChunk: Int, expected: Int, available: Int)
        case chunkSizeMismatch(atChunk: Int, detail: String)

        public var description: String {
            switch self {
            case let .unreadable(path):
                return "\(path) could not be read."
            case let .unsupportedVersion(major, minor):
                return """
                    This is a sparse image of version \(major).\(minor); only major version 1 \
                    is understood.
                    """
            case let .implausibleBlockSize(size):
                return "The sparse image declares a block size of \(size), which is not a multiple of 4."
            case let .unknownChunkType(raw, chunk):
                return String(format: "Chunk %d has unknown type 0x%04X.", chunk, raw)
            case let .truncated(chunk, expected, available):
                return "Chunk \(chunk) needs \(expected) bytes but only \(available) remain."
            case let .chunkSizeMismatch(chunk, detail):
                return "Chunk \(chunk) is inconsistent: \(detail)"
            }
        }
    }

    // MARK: - Reading

    /// Reads the header, or returns `nil` when the file is not a sparse image.
    ///
    /// Returning `nil` rather than throwing is deliberate: "this is an ordinary
    /// raw image" is the common case, not an error.
    public static func readHeader(at url: URL) throws -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure.unreadable(path: url.path)
        }
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 28), head.count == 28 else { return nil }
        return try parseHeader(head)
    }

    static func parseHeader(_ data: Data) throws -> Header? {
        func word(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        func half(_ offset: Int) -> UInt16 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        }
        guard data.count >= 28, word(0) == magic else { return nil }

        let header = Header(
            majorVersion: half(4),
            minorVersion: half(6),
            fileHeaderSize: half(8),
            chunkHeaderSize: half(10),
            blockSizeBytes: word(12),
            totalBlocks: word(16),
            totalChunks: word(20))

        guard header.majorVersion == 1 else {
            throw Failure.unsupportedVersion(major: header.majorVersion, minor: header.minorVersion)
        }
        // libsparse requires a block size that is a multiple of 4, because fill
        // chunks are written as repeated 32-bit words.
        guard header.blockSizeBytes > 0, header.blockSizeBytes % 4 == 0 else {
            throw Failure.implausibleBlockSize(header.blockSizeBytes)
        }
        return header
    }

    /// True when the file is a sparse container.
    public static func isSparse(at url: URL) -> Bool {
        ((try? readHeader(at: url)) ?? nil) != nil
    }

    /// The size this file occupies once expanded, or its size on disk when it
    /// is not sparse. This is the size a partition holding it must have.
    public static func expandedSize(at url: URL) throws -> UInt64 {
        if let header = try readHeader(at: url) { return header.expandedSizeBytes }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: - Expanding

    /// Reads the first `byteCount` bytes of the image as the guest would see
    /// them, expanding only as far as it must.
    ///
    /// `expand` writes the whole thing to a file handle, which is right for
    /// building a disk and absurd for answering a question about a superblock:
    /// `userdata.img` expands to 8 GiB and the filesystem magic lives in the
    /// first 4 KiB. This stops as soon as it has enough.
    ///
    /// A file that is not sparse is simply read directly, so callers do not
    /// have to know which they have.
    public static func expandedPrefix(at url: URL, byteCount: Int) throws -> Data {
        guard let header = try readHeader(at: url) else {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: byteCount) ?? Data()
        }
        guard let source = try? FileHandle(forReadingFrom: url) else {
            throw Failure.unreadable(path: url.path)
        }
        defer { try? source.close() }

        try source.seek(toOffset: UInt64(header.fileHeaderSize))
        var output = Data()
        let blockSize = Int(header.blockSizeBytes)

        for _ in 0..<header.totalChunks where output.count < byteCount {
            guard let raw = try source.read(upToCount: Int(header.chunkHeaderSize)),
                  raw.count == Int(header.chunkHeaderSize) else { break }
            let type = raw.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
            let blocks = raw.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            }
            let totalBytes = raw.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            }
            let payload = Int(totalBytes) - Int(header.chunkHeaderSize)
            let span = Int(blocks) * blockSize

            switch type {
            case ChunkType.raw.rawValue:
                let wanted = min(payload, byteCount - output.count)
                if let bytes = try source.read(upToCount: wanted) { output.append(bytes) }
                if payload > wanted { try source.seek(toOffset: source.offsetInFile + UInt64(payload - wanted)) }
            case ChunkType.fill.rawValue:
                guard let pattern = try source.read(upToCount: payload), pattern.count == 4 else { break }
                let wanted = min(span, byteCount - output.count)
                var filled = Data(capacity: wanted)
                while filled.count < wanted { filled.append(pattern) }
                output.append(filled.prefix(wanted))
            case ChunkType.dontCare.rawValue:
                // A run nobody wrote reads back as zeros.
                let wanted = min(span, byteCount - output.count)
                output.append(Data(repeating: 0, count: wanted))
            default:
                if payload > 0 { try source.seek(toOffset: source.offsetInFile + UInt64(payload)) }
            }
        }
        return output
    }

    /// Expands a sparse image into an already-open destination.
    ///
    /// Written in chunks rather than by materialising the whole image, because
    /// `super.img` expands to 8 GiB and holding that in memory to copy it would
    /// be absurd. Runs nobody wrote are skipped by seeking, which leaves them
    /// as holes on a sparse filesystem rather than gigabytes of written zeros.
    @discardableResult
    public static func expand(
        from url: URL,
        into destination: FileHandle,
        startingAt destinationOffset: UInt64,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> UInt64 {
        guard let header = try readHeader(at: url) else {
            throw Failure.unreadable(path: url.path)
        }
        guard let source = try? FileHandle(forReadingFrom: url) else {
            throw Failure.unreadable(path: url.path)
        }
        defer { try? source.close() }

        try source.seek(toOffset: UInt64(header.fileHeaderSize))
        let blockSize = Int(header.blockSizeBytes)
        var written: UInt64 = 0

        for index in 0..<Int(header.totalChunks) {
            guard let chunkHeader = try source.read(upToCount: Int(header.chunkHeaderSize)),
                  chunkHeader.count == Int(header.chunkHeaderSize) else {
                throw Failure.truncated(atChunk: index, expected: Int(header.chunkHeaderSize), available: 0)
            }
            let rawType = chunkHeader.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
            }
            let blocks = chunkHeader.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            }
            let totalSize = chunkHeader.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            }
            guard let type = ChunkType(rawValue: rawType) else {
                throw Failure.unknownChunkType(rawType, atChunk: index)
            }
            let payloadSize = Int(totalSize) - Int(header.chunkHeaderSize)
            let span = UInt64(blocks) * UInt64(blockSize)

            switch type {
            case .raw:
                guard payloadSize == Int(span) else {
                    throw Failure.chunkSizeMismatch(
                        atChunk: index,
                        detail: "a raw chunk of \(blocks) blocks carries \(payloadSize) bytes")
                }
                try destination.seek(toOffset: destinationOffset + written)
                // Copied in slices so a single chunk cannot pull hundreds of
                // megabytes into memory at once.
                var remaining = payloadSize
                while remaining > 0 {
                    let slice = min(remaining, 8 * 1024 * 1024)
                    guard let data = try source.read(upToCount: slice), data.count == slice else {
                        throw Failure.truncated(atChunk: index, expected: slice, available: 0)
                    }
                    try destination.write(contentsOf: data)
                    remaining -= slice
                }
                written += span

            case .fill:
                guard payloadSize == 4 else {
                    throw Failure.chunkSizeMismatch(
                        atChunk: index, detail: "a fill chunk carries \(payloadSize) bytes, not 4")
                }
                guard let fill = try source.read(upToCount: 4), fill.count == 4 else {
                    throw Failure.truncated(atChunk: index, expected: 4, available: 0)
                }
                // A fill of zero is what a hole already contains, so skip it and
                // leave the space unwritten.
                if fill != Data([0, 0, 0, 0]) {
                    try destination.seek(toOffset: destinationOffset + written)
                    let pattern = Data(repeating: 0, count: blockSize).enumerated().map { offset, _ in
                        fill[fill.startIndex + (offset % 4)]
                    }
                    let block = Data(pattern)
                    for _ in 0..<blocks { try destination.write(contentsOf: block) }
                }
                written += span

            case .dontCare:
                // Nobody wrote these blocks; seeking past them leaves a hole.
                written += span

            case .crc32:
                // Recorded by libsparse, not needed to reconstruct the image.
                if payloadSize > 0 { _ = try source.read(upToCount: payloadSize) }
            }

            if index % 64 == 0, header.totalChunks > 64 {
                progress?("expanding \(url.lastPathComponent): chunk \(index) of \(header.totalChunks)")
            }
        }

        guard written == header.expandedSizeBytes else {
            throw Failure.chunkSizeMismatch(
                atChunk: Int(header.totalChunks),
                detail: "expanded to \(written) bytes, but the header declares \(header.expandedSizeBytes)")
        }
        return written
    }
}
