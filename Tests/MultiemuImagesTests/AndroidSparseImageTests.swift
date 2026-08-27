import Foundation
import Testing
@testable import MultiemuImages

@Suite("Android sparse images")
struct AndroidSparseImageTests {

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-sparse-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Building synthetic images

    /// Assembles a sparse image from chunk descriptions, so the tests exercise
    /// the real parser rather than a mock of it.
    private enum Chunk {
        case raw(Data)
        case fill(UInt32, blocks: UInt32)
        case dontCare(blocks: UInt32)
        case crc32(UInt32)
    }

    private let blockSize: UInt32 = 4096

    private func sparseImage(_ chunks: [Chunk]) -> Data {
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

        var totalBlocks: UInt32 = 0
        var body = Data()
        for chunk in chunks {
            switch chunk {
            case let .raw(payload):
                let blocks = UInt32(payload.count) / blockSize
                totalBlocks += blocks
                body += le16(0xCAC1) + le16(0) + le32(blocks) + le32(UInt32(12 + payload.count))
                body += payload
            case let .fill(word, blocks):
                totalBlocks += blocks
                body += le16(0xCAC2) + le16(0) + le32(blocks) + le32(16)
                body += le32(word)
            case let .dontCare(blocks):
                totalBlocks += blocks
                body += le16(0xCAC3) + le16(0) + le32(blocks) + le32(12)
            case let .crc32(value):
                body += le16(0xCAC4) + le16(0) + le32(0) + le32(16)
                body += le32(value)
            }
        }

        var header = le32(AndroidSparseImage.magic)
        header += le16(1) + le16(0)          // major, minor
        header += le16(28) + le16(12)        // file header size, chunk header size
        header += le32(blockSize)
        header += le32(totalBlocks)
        header += le32(UInt32(chunks.count))
        header += le32(0)                    // image checksum
        return header + body
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: Detection

    @Test("A raw image is not mistaken for a sparse one")
    func rawIsNotSparse() throws {
        let directory = temporaryDirectory()
        let url = try write(Data(repeating: 0xAB, count: 8192), named: "raw.img", in: directory)
        #expect(AndroidSparseImage.isSparse(at: url) == false)
        #expect(try AndroidSparseImage.readHeader(at: url) == nil)
    }

    @Test("A file too short to hold a header is not sparse")
    func shortFileIsNotSparse() throws {
        let directory = temporaryDirectory()
        let url = try write(Data([0x3A, 0xFF, 0x26, 0xED]), named: "stub.img", in: directory)
        #expect(AndroidSparseImage.isSparse(at: url) == false)
    }

    @Test("The declared expanded size, not the file size, is what a partition needs")
    func expandedSizeExceedsFileSize() throws {
        let directory = temporaryDirectory()
        // One written block and a thousand nobody wrote: 4 KiB on disk, 4 MiB expanded.
        let image = sparseImage([
            .raw(Data(repeating: 0x11, count: Int(blockSize))),
            .dontCare(blocks: 1023),
        ])
        let url = try write(image, named: "sparse.img", in: directory)

        let onDisk = try #require(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value)
        let expanded = try AndroidSparseImage.expandedSize(at: url)

        #expect(expanded == 1024 * UInt64(blockSize))
        #expect(expanded > onDisk)
    }

    @Test("A non-sparse file reports its own size")
    func expandedSizeOfRawFile() throws {
        let directory = temporaryDirectory()
        let url = try write(Data(repeating: 0, count: 5000), named: "raw.img", in: directory)
        #expect(try AndroidSparseImage.expandedSize(at: url) == 5000)
    }

    // MARK: Expansion

    @Test("Every chunk type expands to the bytes it stands for")
    func expandReproducesContent() throws {
        let directory = temporaryDirectory()
        let rawPayload = Data((0..<Int(blockSize)).map { UInt8($0 % 251) })
        let image = sparseImage([
            .raw(rawPayload),
            .fill(0xDEAD_BEEF, blocks: 2),
            .dontCare(blocks: 1),
            .crc32(0),
            .raw(Data(repeating: 0x5A, count: Int(blockSize))),
        ])
        let source = try write(image, named: "sparse.img", in: directory)
        let destination = directory.appendingPathComponent("out.img")

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        let written = try AndroidSparseImage.expand(from: source, into: handle, startingAt: 0)
        try handle.close()

        let result = try Data(contentsOf: destination)
        #expect(written == 5 * UInt64(blockSize))

        let block = Int(blockSize)
        // The literal chunk survives byte for byte.
        #expect(result[0..<block] == rawPayload)
        // The fill word repeats little-endian across both its blocks.
        let fillRegion = result[block..<(3 * block)]
        #expect(Set(fillRegion.chunked(4)) == [Data([0xEF, 0xBE, 0xAD, 0xDE])])
        // Blocks nobody wrote read back as zeros.
        #expect(result[(3 * block)..<(4 * block)].allSatisfy { $0 == 0 })
        // And the CRC chunk consumed its payload without displacing what follows.
        #expect(result[(4 * block)..<(5 * block)].allSatisfy { $0 == 0x5A })
    }

    @Test("Expansion honours the destination offset, leaving earlier bytes alone")
    func expandAtOffset() throws {
        let directory = temporaryDirectory()
        let image = sparseImage([.fill(0x0101_0101, blocks: 1)])
        let source = try write(image, named: "sparse.img", in: directory)

        let destination = directory.appendingPathComponent("out.img")
        try Data(repeating: 0x77, count: Int(blockSize) * 3).write(to: destination)

        let handle = try FileHandle(forWritingTo: destination)
        try AndroidSparseImage.expand(from: source, into: handle, startingAt: UInt64(blockSize))
        try handle.close()

        let result = try Data(contentsOf: destination)
        let block = Int(blockSize)
        #expect(result[0..<block].allSatisfy { $0 == 0x77 })
        #expect(result[block..<(2 * block)].allSatisfy { $0 == 0x01 })
        #expect(result[(2 * block)..<(3 * block)].allSatisfy { $0 == 0x77 })
    }

    @Test("A zero fill leaves a hole rather than writing gigabytes of zeros")
    func zeroFillLeavesHole() throws {
        let directory = temporaryDirectory()
        let image = sparseImage([.fill(0, blocks: 256), .raw(Data(repeating: 0x9, count: Int(blockSize)))])
        let source = try write(image, named: "sparse.img", in: directory)
        let destination = directory.appendingPathComponent("out.img")

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        try AndroidSparseImage.expand(from: source, into: handle, startingAt: 0)
        try handle.close()

        let result = try Data(contentsOf: destination)
        #expect(result.count == 257 * Int(blockSize))
        #expect(result[0..<(256 * Int(blockSize))].allSatisfy { $0 == 0 })
    }

    // MARK: Rejection

    @Test("A version this decoder does not understand is refused, not guessed at")
    func rejectsFutureVersion() throws {
        var image = sparseImage([.dontCare(blocks: 1)])
        image.replaceSubrange(4..<6, with: withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        #expect(throws: AndroidSparseImage.Failure.self) {
            _ = try AndroidSparseImage.parseHeader(image)
        }
    }

    @Test("A block size that is not a multiple of four is refused")
    func rejectsImplausibleBlockSize() throws {
        var image = sparseImage([.dontCare(blocks: 1)])
        image.replaceSubrange(12..<16, with: withUnsafeBytes(of: UInt32(4095).littleEndian) { Data($0) })
        #expect(throws: AndroidSparseImage.Failure.self) {
            _ = try AndroidSparseImage.parseHeader(image)
        }
    }

    @Test("An unknown chunk type stops the expansion instead of corrupting the output")
    func rejectsUnknownChunkType() throws {
        let directory = temporaryDirectory()
        var image = sparseImage([.dontCare(blocks: 1)])
        image.replaceSubrange(28..<30, with: withUnsafeBytes(of: UInt16(0xBEEF).littleEndian) { Data($0) })
        let source = try write(image, named: "bad.img", in: directory)

        let destination = directory.appendingPathComponent("out.img")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        #expect(throws: AndroidSparseImage.Failure.self) {
            try AndroidSparseImage.expand(from: source, into: handle, startingAt: 0)
        }
    }

    @Test("An image that expands to less than it declares is refused")
    func rejectsShortExpansion() throws {
        let directory = temporaryDirectory()
        var image = sparseImage([.dontCare(blocks: 4)])
        // Claim eight blocks while the chunks account for four.
        image.replaceSubrange(16..<20, with: withUnsafeBytes(of: UInt32(8).littleEndian) { Data($0) })
        let source = try write(image, named: "short.img", in: directory)

        let destination = directory.appendingPathComponent("out.img")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        #expect(throws: AndroidSparseImage.Failure.self) {
            try AndroidSparseImage.expand(from: source, into: handle, startingAt: 0)
        }
    }
}

private extension Data {
    /// Splits into equal-size pieces, for asserting that a fill pattern repeats.
    func chunked(_ size: Int) -> [Data] {
        stride(from: startIndex, to: endIndex, by: size).map {
            Data(self[$0..<Swift.min($0 + size, endIndex)])
        }
    }
}
