import Foundation
import MultiemuSupport

/// Assembles Android partition images into one GPT-partitioned disk.
///
/// Android locates its partitions through `/dev/block/by-name/` symlinks that
/// ueventd derives from partition names. Cuttlefish-style images assume a single
/// disk carrying GPT partitions with those names — which is what `cvd` builds on
/// Linux and what Multiemu must build here.
///
/// The output is a **sparse** raw file: the disk is created at its full logical
/// size, but only the GPT structures and the partition payloads are written, so
/// unwritten regions cost nothing on APFS. That satisfies the product rule
/// against eagerly allocating virtual disks.
public struct CompositeDiskBuilder: Sendable {

    public static let sectorSize: UInt64 = 512
    /// Partitions are aligned to 1 MiB, the universal convention.
    public static let alignmentSectors: UInt64 = 2048
    public static let partitionEntryCount: UInt64 = 128
    public static let partitionEntrySize: UInt64 = 128

    /// "Linux filesystem data" — the type Android uses for its partitions.
    public static let linuxFilesystemData = GUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4")!

    public struct Partition: Sendable, Equatable {
        /// GPT partition name. This is what becomes `/dev/block/by-name/<name>`.
        public var name: String
        /// Source image, or `nil` for an empty partition of `sizeBytes`.
        public var sourceURL: URL?
        /// Explicit size. When `nil`, the source file's size is used.
        public var sizeBytes: UInt64?
        public var typeGUID: GUID

        public init(name: String, sourceURL: URL? = nil, sizeBytes: UInt64? = nil,
                    typeGUID: GUID = CompositeDiskBuilder.linuxFilesystemData) {
            self.name = name
            self.sourceURL = sourceURL
            self.sizeBytes = sizeBytes
            self.typeGUID = typeGUID
        }
    }

    public struct PlacedPartition: Sendable, Equatable {
        public var name: String
        public var firstLBA: UInt64
        public var lastLBA: UInt64
        public var sizeBytes: UInt64
        public var byteOffset: UInt64 { firstLBA * CompositeDiskBuilder.sectorSize }
    }

    public struct Layout: Sendable, Equatable {
        public var diskURL: URL
        public var totalSizeBytes: UInt64
        public var partitions: [PlacedPartition]
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noPartitions
        case unknownSize(partition: String)
        case sourceTooLarge(partition: String, sourceBytes: UInt64, declaredBytes: UInt64)
        case nameTooLong(partition: String, limit: Int)
        case duplicateName(String)
        case tooManyPartitions(count: Int, limit: Int)

        public var description: String {
            switch self {
            case .noPartitions:
                return "A composite disk needs at least one partition."
            case let .unknownSize(partition):
                return "Partition \"\(partition)\" has neither a source image nor an explicit size."
            case let .sourceTooLarge(partition, sourceBytes, declaredBytes):
                return "Partition \"\(partition)\" declares \(ByteCount.describe(declaredBytes)) but its image is \(ByteCount.describe(sourceBytes))."
            case let .nameTooLong(partition, limit):
                return "Partition name \"\(partition)\" exceeds the GPT limit of \(limit) UTF-16 characters."
            case let .duplicateName(name):
                return "Two partitions are both named \"\(name)\"; Android resolves partitions by name, so they must be unique."
            case let .tooManyPartitions(count, limit):
                return "\(count) partitions exceeds the \(limit)-entry GPT table."
            }
        }
    }

    /// Relax Android Verified Boot on the vbmeta partitions written into this
    /// disk.
    ///
    /// **Off by default, and it weakens a security check.** AVB refuses to
    /// mount partitions signed by a key the device does not trust, and nobody
    /// holds the signing key for an AOSP CI build — so without this the guest
    /// stops at "Found unknown public key used to sign /system". Setting it
    /// means the guest mounts partitions whose signature nothing verified.
    ///
    /// Only the generated composite disk is affected. The installed image is
    /// left untouched, and the manifest still checks its SHA-256 before every
    /// boot, so provenance is still established — just not by AVB.
    public var relaxesVerifiedBoot = false

    public init() {}

    /// Computes the layout without writing anything.
    public func plan(_ partitions: [Partition]) throws -> [PlacedPartition] {
        guard !partitions.isEmpty else { throw Failure.noPartitions }
        guard partitions.count <= Int(Self.partitionEntryCount) else {
            throw Failure.tooManyPartitions(count: partitions.count, limit: Int(Self.partitionEntryCount))
        }
        var names = Set<String>()
        for partition in partitions {
            guard partition.name.utf16.count <= 36 else {
                throw Failure.nameTooLong(partition: partition.name, limit: 36)
            }
            guard names.insert(partition.name).inserted else {
                throw Failure.duplicateName(partition.name)
            }
        }

        // LBA 0 protective MBR, LBA 1 header, LBAs 2..33 entry array.
        var cursor = Self.alignmentSectors
        var placed: [PlacedPartition] = []

        for partition in partitions {
            // The size that matters is what the source expands to, not what it
            // occupies. A sparse super.img of 1.63 GiB becomes an 8 GiB
            // partition, and sizing it by the file would truncate it.
            let sourceSize: UInt64? = partition.sourceURL.flatMap { url in
                try? AndroidSparseImage.expandedSize(at: url)
            }
            guard let size = partition.sizeBytes ?? sourceSize else {
                throw Failure.unknownSize(partition: partition.name)
            }
            if let sourceSize, let declared = partition.sizeBytes, sourceSize > declared {
                throw Failure.sourceTooLarge(partition: partition.name, sourceBytes: sourceSize, declaredBytes: declared)
            }

            let sectors = max(1, (size + Self.sectorSize - 1) / Self.sectorSize)
            placed.append(PlacedPartition(
                name: partition.name,
                firstLBA: cursor,
                lastLBA: cursor + sectors - 1,
                sizeBytes: size
            ))
            // Align the next partition.
            cursor += ((sectors + Self.alignmentSectors - 1) / Self.alignmentSectors) * Self.alignmentSectors
        }
        return placed
    }

    /// Writes the composite disk.
    @discardableResult
    public func build(
        partitions: [Partition],
        to url: URL,
        diskGUIDSeed: String = "multiemu",
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> Layout {
        let placed = try plan(partitions)

        // Reserve room for the backup entry array and header at the end.
        let entryArraySectors = (Self.partitionEntryCount * Self.partitionEntrySize) / Self.sectorSize
        let lastPartitionEnd = placed.last!.lastLBA
        let backupEntryArrayLBA = ((lastPartitionEnd + Self.alignmentSectors) / Self.alignmentSectors + 1) * Self.alignmentSectors
        let backupHeaderLBA = backupEntryArrayLBA + entryArraySectors
        let totalSectors = backupHeaderLBA + 1
        let totalBytes = totalSectors * Self.sectorSize

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        // Establish the full logical size without writing it. On APFS the file
        // stays sparse, so a 16 GiB disk costs only what is actually written.
        try handle.truncate(atOffset: totalBytes)

        // --- Partition payloads ---
        for (index, partition) in partitions.enumerated() {
            guard let sourceURL = partition.sourceURL else { continue }
            let target = placed[index]
            progress?("writing \(target.name) at LBA \(target.firstLBA)")

            // A vbmeta partition may need its verification flags relaxed on the
            // way in. Reading one whole is affordable — they are kilobytes,
            // not the gigabytes `super` runs to.
            if relaxesVerifiedBoot, target.name.hasPrefix("vbmeta"),
               let original = FileManager.default.contents(atPath: sourceURL.path),
               AndroidVerifiedBoot.isVBMeta(original) {
                let relaxed = try AndroidVerifiedBoot.settingFlags(.relaxed, in: original)
                progress?("  \(target.name): verified boot relaxed (\(AndroidVerifiedBoot.Flags.relaxed.description))")
                try handle.seek(toOffset: target.byteOffset)
                try handle.write(contentsOf: relaxed)
                continue
            }

            if AndroidSparseImage.isSparse(at: sourceURL) {
                // Expanded in place rather than to a temporary file: super.img
                // becomes 8 GiB, and writing it twice to reach the same result
                // would cost time and disk for nothing.
                progress?("  \(target.name) is a sparse image; expanding")
                try AndroidSparseImage.expand(
                    from: sourceURL, into: handle,
                    startingAt: target.byteOffset, progress: progress)
            } else {
                let reader = try FileHandle(forReadingFrom: sourceURL)
                defer { try? reader.close() }
                try handle.seek(toOffset: target.byteOffset)
                while true {
                    let chunk = try reader.read(upToCount: 8 * 1024 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    try handle.write(contentsOf: chunk)
                }
            }
        }

        // --- Partition entry array ---
        var entries = Data(count: Int(Self.partitionEntryCount * Self.partitionEntrySize))
        for (index, partition) in partitions.enumerated() {
            let target = placed[index]
            var entry = Data()
            entry.append(contentsOf: partition.typeGUID.bytes)
            entry.append(contentsOf: GUID.deterministic(from: "\(diskGUIDSeed)/\(partition.name)").bytes)
            withUnsafeBytes(of: target.firstLBA.littleEndian) { entry.append(contentsOf: $0) }
            withUnsafeBytes(of: target.lastLBA.littleEndian) { entry.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt64(0).littleEndian) { entry.append(contentsOf: $0) }  // attributes
            var name = Data()
            for unit in partition.name.utf16 {
                withUnsafeBytes(of: unit.littleEndian) { name.append(contentsOf: $0) }
            }
            name.append(Data(count: 72 - name.count))
            entry.append(name)
            precondition(entry.count == Int(Self.partitionEntrySize))
            let start = index * Int(Self.partitionEntrySize)
            entries.replaceSubrange(start..<(start + entry.count), with: entry)
        }
        let entriesCRC = CRC32.compute(entries)

        // --- Protective MBR (LBA 0) ---
        var mbr = Data(count: Int(Self.sectorSize))
        mbr[446] = 0x00                                   // boot indicator
        mbr[447] = 0x00; mbr[448] = 0x02; mbr[449] = 0x00 // CHS first
        mbr[450] = 0xEE                                   // type: GPT protective
        mbr[451] = 0xFF; mbr[452] = 0xFF; mbr[453] = 0xFF // CHS last
        withUnsafeBytes(of: UInt32(1).littleEndian) { bytes in
            mbr.replaceSubrange(454..<458, with: bytes)
        }
        let mbrSectors = UInt32(min(totalSectors - 1, UInt64(UInt32.max)))
        withUnsafeBytes(of: mbrSectors.littleEndian) { bytes in
            mbr.replaceSubrange(458..<462, with: bytes)
        }
        mbr[510] = 0x55; mbr[511] = 0xAA
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: mbr)

        // --- Primary and backup GPT headers ---
        let diskGUID = GUID.deterministic(from: diskGUIDSeed)
        let firstUsableLBA: UInt64 = 2 + entryArraySectors
        let lastUsableLBA = backupEntryArrayLBA - 1

        let primaryHeader = makeHeader(
            currentLBA: 1, backupLBA: backupHeaderLBA,
            firstUsableLBA: firstUsableLBA, lastUsableLBA: lastUsableLBA,
            diskGUID: diskGUID, entryArrayLBA: 2, entriesCRC: entriesCRC
        )
        try handle.seek(toOffset: Self.sectorSize)
        try handle.write(contentsOf: primaryHeader)
        try handle.seek(toOffset: 2 * Self.sectorSize)
        try handle.write(contentsOf: entries)

        let backupHeader = makeHeader(
            currentLBA: backupHeaderLBA, backupLBA: 1,
            firstUsableLBA: firstUsableLBA, lastUsableLBA: lastUsableLBA,
            diskGUID: diskGUID, entryArrayLBA: backupEntryArrayLBA, entriesCRC: entriesCRC
        )
        try handle.seek(toOffset: backupEntryArrayLBA * Self.sectorSize)
        try handle.write(contentsOf: entries)
        try handle.seek(toOffset: backupHeaderLBA * Self.sectorSize)
        try handle.write(contentsOf: backupHeader)

        try handle.synchronize()
        progress?("composite disk \(ByteCount.describe(totalBytes)) logical, \(placed.count) partitions")

        return Layout(diskURL: url, totalSizeBytes: totalBytes, partitions: placed)
    }

    /// Builds a 92-byte GPT header padded to one sector.
    private func makeHeader(
        currentLBA: UInt64, backupLBA: UInt64,
        firstUsableLBA: UInt64, lastUsableLBA: UInt64,
        diskGUID: GUID, entryArrayLBA: UInt64, entriesCRC: UInt32
    ) -> Data {
        var header = Data()
        header.append(contentsOf: Array("EFI PART".utf8))
        withUnsafeBytes(of: UInt32(0x0001_0000).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(92).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { header.append(contentsOf: $0) }   // header CRC placeholder
        withUnsafeBytes(of: UInt32(0).littleEndian) { header.append(contentsOf: $0) }   // reserved
        withUnsafeBytes(of: currentLBA.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: backupLBA.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: firstUsableLBA.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: lastUsableLBA.littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: diskGUID.bytes)
        withUnsafeBytes(of: entryArrayLBA.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(Self.partitionEntryCount).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(Self.partitionEntrySize).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: entriesCRC.littleEndian) { header.append(contentsOf: $0) }
        precondition(header.count == 92)

        // The header CRC is computed over the 92 header bytes with its own CRC
        // field zeroed, which it already is.
        let crc = CRC32.compute(header)
        withUnsafeBytes(of: crc.littleEndian) { bytes in
            header.replaceSubrange(16..<20, with: bytes)
        }

        header.append(Data(count: Int(Self.sectorSize) - header.count))
        return header
    }
}
