import Foundation
import MultiemuSupport
import Testing
@testable import MultiemuImages

@Suite("GPT composite disk")
struct CompositeDiskTests {

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiemu-gpt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeImage(_ marker: UInt8, bytes: Int, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data([UInt8](repeating: marker, count: bytes)).write(to: url)
        return url
    }

    // MARK: GUID

    @Test("GUIDs convert to and from the GPT mixed-endian on-disk order")
    func guidMixedEndian() throws {
        let text = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
        let guid = try #require(GUID(text))
        // First three fields are byte-swapped on disk; the last two are not.
        #expect(guid.bytes[0] == 0xAF && guid.bytes[3] == 0x0F)
        #expect(guid.bytes[4] == 0x83 && guid.bytes[5] == 0x84)
        #expect(guid.bytes[8] == 0x8E && guid.bytes[15] == 0xE4)
        #expect(guid.description.uppercased() == text)
    }

    @Test("Malformed GUID text is rejected")
    func guidRejectsBadInput() {
        #expect(GUID("not-a-guid") == nil)
        #expect(GUID("0FC63DAF-8483-4772-8E79-3D69D8477DE") == nil)
    }

    @Test("Derived GUIDs are deterministic and well formed")
    func deterministicGUID() {
        let first = GUID.deterministic(from: "device-a/boot")
        #expect(first == GUID.deterministic(from: "device-a/boot"))
        #expect(first != GUID.deterministic(from: "device-a/userdata"))
        // Version 4, RFC 4122 variant, checked in on-disk order.
        #expect((first.bytes[7] & 0xF0) == 0x40)
        #expect((first.bytes[8] & 0xC0) == 0x80)
    }

    @Test("CRC-32 matches the published check value")
    func crc32KnownVector() {
        // The IEEE 802.3 check value for "123456789".
        #expect(CRC32.compute(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    // MARK: Layout

    @Test("Partitions are 1 MiB aligned and never overlap")
    func layoutAlignment() throws {
        let builder = CompositeDiskBuilder()
        let placed = try builder.plan([
            .init(name: "boot_a", sizeBytes: 3000),
            .init(name: "vendor_boot_a", sizeBytes: 70_000),
            .init(name: "super", sizeBytes: 4_000_000),
        ])
        #expect(placed[0].firstLBA == 2048)
        for partition in placed {
            #expect(partition.firstLBA % CompositeDiskBuilder.alignmentSectors == 0,
                    "\(partition.name) is not 1 MiB aligned")
        }
        for (earlier, later) in zip(placed, placed.dropFirst()) {
            #expect(earlier.lastLBA < later.firstLBA, "\(earlier.name) overlaps \(later.name)")
        }
    }

    @Test("A partition without a size or a source is rejected")
    func rejectsUnknownSize() {
        #expect(throws: CompositeDiskBuilder.Failure.self) {
            try CompositeDiskBuilder().plan([.init(name: "mystery")])
        }
    }

    @Test("Duplicate partition names are rejected, because Android resolves by name")
    func rejectsDuplicateNames() {
        #expect(throws: CompositeDiskBuilder.Failure.self) {
            try CompositeDiskBuilder().plan([
                .init(name: "boot_a", sizeBytes: 1024),
                .init(name: "boot_a", sizeBytes: 1024),
            ])
        }
    }

    @Test("Names longer than the 36-character GPT field are rejected")
    func rejectsLongNames() {
        #expect(throws: CompositeDiskBuilder.Failure.self) {
            try CompositeDiskBuilder().plan([
                .init(name: String(repeating: "x", count: 37), sizeBytes: 1024)
            ])
        }
    }

    @Test("An image larger than its declared partition is rejected")
    func rejectsOversizedSource() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try writeImage(0x11, bytes: 8192, named: "boot.img", in: directory)
        #expect(throws: CompositeDiskBuilder.Failure.self) {
            try CompositeDiskBuilder().plan([
                .init(name: "boot_a", sourceURL: image, sizeBytes: 4096)
            ])
        }
    }

    // MARK: Building

    @Test("A built disk carries a protective MBR and a valid primary GPT header")
    func headerStructure() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let boot = try writeImage(0xA1, bytes: 65536, named: "boot.img", in: directory)
        let diskURL = directory.appendingPathComponent("composite.img")

        let layout = try CompositeDiskBuilder().build(
            partitions: [.init(name: "boot_a", sourceURL: boot)],
            to: diskURL
        )
        let data = try Data(contentsOf: diskURL)

        // Protective MBR.
        #expect(data[450] == 0xEE)
        #expect(data[510] == 0x55 && data[511] == 0xAA)

        // Primary header at LBA 1.
        let headerStart = 512
        #expect(String(decoding: data[headerStart..<(headerStart + 8)], as: UTF8.self) == "EFI PART")

        // The header CRC must validate with its own field zeroed.
        var header = Array(data[headerStart..<(headerStart + 92)])
        let storedCRC = UInt32(header[16]) | UInt32(header[17]) << 8 | UInt32(header[18]) << 16 | UInt32(header[19]) << 24
        header[16...19] = [0, 0, 0, 0]
        #expect(CRC32.compute(header) == storedCRC)

        #expect(layout.partitions.count == 1)
        #expect(layout.totalSizeBytes > 0)
    }

    @Test("Partition payloads land exactly at their declared offsets")
    func payloadPlacement() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let boot = try writeImage(0xA1, bytes: 4096, named: "boot.img", in: directory)
        let vendor = try writeImage(0xB2, bytes: 8192, named: "vendor_boot.img", in: directory)
        let diskURL = directory.appendingPathComponent("composite.img")

        let layout = try CompositeDiskBuilder().build(
            partitions: [
                .init(name: "boot_a", sourceURL: boot),
                .init(name: "vendor_boot_a", sourceURL: vendor),
            ],
            to: diskURL
        )
        let data = try Data(contentsOf: diskURL)

        for (placed, marker) in zip(layout.partitions, [UInt8(0xA1), 0xB2]) {
            let start = Int(placed.byteOffset)
            let slice = data[start..<(start + Int(placed.sizeBytes))]
            #expect(slice.allSatisfy { $0 == marker }, "\(placed.name) payload is wrong")
        }
    }

    @Test("The disk is created sparse, not fully allocated")
    func diskIsSparse() throws {
        // The product rule is explicit: never eagerly allocate a virtual disk
        // when the filesystem supports sparse files.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let boot = try writeImage(0xA1, bytes: 4096, named: "boot.img", in: directory)
        let diskURL = directory.appendingPathComponent("composite.img")

        let layout = try CompositeDiskBuilder().build(
            partitions: [
                .init(name: "boot_a", sourceURL: boot),
                .init(name: "userdata", sizeBytes: 512 * ByteCount.miB),
            ],
            to: diskURL
        )
        #expect(layout.totalSizeBytes > 512 * ByteCount.miB)

        let values = try diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        let allocated = UInt64(values.totalFileAllocatedSize ?? 0)
        let logical = UInt64(values.fileSize ?? 0)
        #expect(logical >= 512 * ByteCount.miB)
        // Allocated blocks should be a tiny fraction of the logical size.
        #expect(allocated < 16 * ByteCount.miB, "disk allocated \(ByteCount.describe(allocated))")
    }

    @Test("Partition names round-trip as UTF-16 in the entry array")
    func partitionNamesInEntries() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let diskURL = directory.appendingPathComponent("composite.img")
        _ = try CompositeDiskBuilder().build(
            partitions: [.init(name: "userdata", sizeBytes: 1 * ByteCount.miB)],
            to: diskURL
        )
        let data = try Data(contentsOf: diskURL)
        let entryStart = 2 * 512
        let nameBytes = Array(data[(entryStart + 56)..<(entryStart + 56 + 72)])
        var units: [UInt16] = []
        for index in stride(from: 0, to: 72, by: 2) {
            let unit = UInt16(nameBytes[index]) | UInt16(nameBytes[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        #expect(String(decoding: units, as: UTF16.self) == "userdata")
    }

    @Test("Backup GPT mirrors the primary")
    func backupHeader() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let diskURL = directory.appendingPathComponent("composite.img")
        let layout = try CompositeDiskBuilder().build(
            partitions: [.init(name: "boot_a", sizeBytes: 1 * ByteCount.miB)],
            to: diskURL
        )
        let data = try Data(contentsOf: diskURL)
        let backupHeaderOffset = Int(layout.totalSizeBytes) - 512
        #expect(String(decoding: data[backupHeaderOffset..<(backupHeaderOffset + 8)], as: UTF8.self) == "EFI PART")

        var header = Array(data[backupHeaderOffset..<(backupHeaderOffset + 92)])
        let storedCRC = UInt32(header[16]) | UInt32(header[17]) << 8 | UInt32(header[18]) << 16 | UInt32(header[19]) << 24
        header[16...19] = [0, 0, 0, 0]
        #expect(CRC32.compute(header) == storedCRC)
    }
}
