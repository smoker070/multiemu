import Foundation
import MultiemuSupport

/// Parser for Android `boot.img` and `vendor_boot.img` containers.
///
/// Multiemu boots guests by direct kernel boot, so every Android image has to be
/// split into the kernel and ramdisk files QEMU's `-kernel`/`-initrd` expect.
/// That split is this type's entire job.
///
/// Field layouts follow AOSP's `system/tools/mkbootimg/include/bootimg/bootimg.h`.
/// Header versions 0–4 are supported for `boot.img` and 3–4 for `vendor_boot.img`.
/// See `docs/VERIFY.md` → `BOOT-IMAGE-HEADER-LAYOUT`: the layouts here are
/// implemented from the documented structures and covered by round-trip tests
/// against synthetic images, but have not yet been validated against a real
/// Google- or AOSP-produced image.
public enum AndroidBootImage {

    public static let bootMagic = "ANDROID!"
    public static let vendorBootMagic = "VNDRBOOT"

    /// Header versions 3 and later fix the page size at 4096 rather than
    /// storing it, so the field is absent from those headers.
    public static let fixedPageSizeForVersion3AndLater = 4096

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notABootImage(foundMagic: String)
        case notAVendorBootImage(foundMagic: String)
        case unsupportedHeaderVersion(UInt32, supported: ClosedRange<UInt32>)
        case implausiblePageSize(UInt32)
        case sectionOutOfBounds(section: String, offset: Int, size: Int, fileSize: Int)
        case emptyKernel
        case truncatedHeader(String)

        public var description: String {
            switch self {
            case let .notABootImage(magic):
                return "Not an Android boot image: expected magic \"\(AndroidBootImage.bootMagic)\", found \"\(magic)\"."
            case let .notAVendorBootImage(magic):
                return "Not an Android vendor boot image: expected magic \"\(AndroidBootImage.vendorBootMagic)\", found \"\(magic)\"."
            case let .unsupportedHeaderVersion(version, supported):
                return "Boot image header version \(version) is not supported (supported: \(supported.lowerBound)–\(supported.upperBound))."
            case let .implausiblePageSize(size):
                return "Boot image declares a page size of \(size), which is not a power of two between 512 and 65536."
            case let .sectionOutOfBounds(section, offset, size, fileSize):
                return "The \(section) section claims \(size) bytes at offset \(offset), past the end of a \(fileSize)-byte file."
            case .emptyKernel:
                return "The boot image contains no kernel."
            case let .truncatedHeader(detail):
                return "The image header is truncated: \(detail)"
            }
        }
    }

    // MARK: - boot.img

    public struct BootImage: Sendable, Equatable {
        public var headerVersion: UInt32
        public var pageSize: Int
        /// Encoded `os_version`/`os_patch_level`, decoded below.
        public var osVersion: String?
        public var osPatchLevel: String?
        public var productName: String
        public var kernelCommandLine: String

        /// Absent in `init_boot.img`, which carries only the generic
        /// ramdisk. Every other boot image has one.
        public var kernelRange: Range<Int>?
        public var ramdiskRange: Range<Int>?
        public var secondStageRange: Range<Int>?
        public var recoveryDTBORange: Range<Int>?
        public var dtbRange: Range<Int>?

        public var hasRamdisk: Bool { ramdiskRange.map { !$0.isEmpty } ?? false }
    }

    /// Parses a `boot.img` header and locates its sections.
    /// Parses a boot image.
    ///
    /// `requiresKernel` is false for `init_boot.img`, which Android 13 and later
    /// use to carry the generic ramdisk on its own. Insisting on a kernel there
    /// rejects a perfectly valid image.
    public static func parseBootImage(_ data: Data, requiresKernel: Bool = true) throws -> BootImage {
        var reader = ByteReader(data)

        let magic = try reader.fixedString(8)
        guard magic == bootMagic else { throw Failure.notABootImage(foundMagic: magic) }

        // Both header families begin with kernel_size, but diverge immediately
        // after, so the version has to be read before anything else is trusted.
        let headerVersion = try peekHeaderVersion(data)
        switch headerVersion {
        case 0...2:
            return try parseBootImageV0toV2(
                data, headerVersion: headerVersion, requiresKernel: requiresKernel)
        case 3...4:
            return try parseBootImageV3toV4(
                data, headerVersion: headerVersion, requiresKernel: requiresKernel)
        default: throw Failure.unsupportedHeaderVersion(headerVersion, supported: 0...4)
        }
    }

    /// `header_version` sits at a different offset in each header family, so it
    /// is read by trying the v3+ position first and falling back.
    private static func peekHeaderVersion(_ data: Data) throws -> UInt32 {
        // v3/v4: magic(8) + kernel_size(4) + ramdisk_size(4) + os_version(4)
        //        + header_size(4) + reserved(16) => header_version at 40.
        // v0-v2: magic(8) + 8 uint32 fields => header_version at 40 as well.
        //
        // The two families genuinely place header_version at the same offset;
        // that is what makes version-first parsing possible at all.
        var reader = ByteReader(data, offset: 40)
        do {
            return try reader.uint32()
        } catch {
            throw Failure.truncatedHeader("could not read header_version at offset 40")
        }
    }

    private static func parseBootImageV0toV2(
        _ data: Data, headerVersion: UInt32, requiresKernel: Bool
    ) throws -> BootImage {
        var reader = ByteReader(data, offset: 8)  // past magic

        let kernelSize = Int(try reader.uint32())
        _ = try reader.uint32()                    // kernel_addr
        let ramdiskSize = Int(try reader.uint32())
        _ = try reader.uint32()                    // ramdisk_addr
        let secondSize = Int(try reader.uint32())
        _ = try reader.uint32()                    // second_addr
        _ = try reader.uint32()                    // tags_addr
        let pageSizeRaw = try reader.uint32()
        _ = try reader.uint32()                    // header_version (already read)
        let osVersionRaw = try reader.uint32()
        let name = try reader.fixedString(16)
        let commandLine = try reader.fixedString(512)
        try reader.skip(32)                        // id[8]
        let extraCommandLine = try reader.fixedString(1024)

        let pageSize = try validatedPageSize(pageSizeRaw)

        var recoveryDTBOSize = 0
        var dtbSize = 0
        if headerVersion >= 1 {
            recoveryDTBOSize = Int(try reader.uint32())
            _ = try reader.uint64()                // recovery_dtbo_offset
            _ = try reader.uint32()                // header_size
        }
        if headerVersion >= 2 {
            dtbSize = Int(try reader.uint32())
            _ = try reader.uint64()                // dtb_addr
        }

        // Sections follow the header, each starting on a page boundary. The
        // header occupies ceil(headerSize / pageSize) pages — normally one, but
        // never assume it: a header larger than a page would otherwise place
        // every section one page early and yield a kernel that is almost right.
        var cursor = roundUpToMultiple(reader.offset, of: pageSize)
        let kernel = try section("kernel", at: &cursor, size: kernelSize, pageSize: pageSize, fileSize: data.count)
        let ramdisk = try section("ramdisk", at: &cursor, size: ramdiskSize, pageSize: pageSize, fileSize: data.count)
        let second = try section("second stage", at: &cursor, size: secondSize, pageSize: pageSize, fileSize: data.count)
        let recoveryDTBO = try section("recovery DTBO", at: &cursor, size: recoveryDTBOSize, pageSize: pageSize, fileSize: data.count)
        let dtb = try section("DTB", at: &cursor, size: dtbSize, pageSize: pageSize, fileSize: data.count)

        if requiresKernel, kernel == nil || kernel?.isEmpty == true {
            throw Failure.emptyKernel
        }

        let fullCommandLine = (commandLine + extraCommandLine).trimmingCharacters(in: .whitespaces)
        let (version, patchLevel) = decodeOSVersion(osVersionRaw)

        return BootImage(
            headerVersion: headerVersion,
            pageSize: pageSize,
            osVersion: version,
            osPatchLevel: patchLevel,
            productName: name,
            kernelCommandLine: fullCommandLine,
            kernelRange: kernel,
            ramdiskRange: ramdisk,
            secondStageRange: second,
            recoveryDTBORange: recoveryDTBO,
            dtbRange: dtb
        )
    }

    private static func parseBootImageV3toV4(
        _ data: Data, headerVersion: UInt32, requiresKernel: Bool
    ) throws -> BootImage {
        var reader = ByteReader(data, offset: 8)  // past magic

        let kernelSize = Int(try reader.uint32())
        let ramdiskSize = Int(try reader.uint32())
        let osVersionRaw = try reader.uint32()
        _ = try reader.uint32()                    // header_size
        try reader.skip(16)                        // reserved[4]
        _ = try reader.uint32()                    // header_version (already read)
        let commandLine = try reader.fixedString(1536)

        // Version 3 and later fix the page size rather than storing it.
        let pageSize = fixedPageSizeForVersion3AndLater

        var cursor = roundUpToMultiple(reader.offset, of: pageSize)
        let kernel = try section("kernel", at: &cursor, size: kernelSize, pageSize: pageSize, fileSize: data.count)
        let ramdisk = try section("ramdisk", at: &cursor, size: ramdiskSize, pageSize: pageSize, fileSize: data.count)

        if requiresKernel, kernel == nil || kernel?.isEmpty == true {
            throw Failure.emptyKernel
        }

        let (version, patchLevel) = decodeOSVersion(osVersionRaw)
        return BootImage(
            headerVersion: headerVersion,
            pageSize: pageSize,
            osVersion: version,
            osPatchLevel: patchLevel,
            productName: "",
            kernelCommandLine: commandLine,
            kernelRange: kernel,
            ramdiskRange: ramdisk,
            secondStageRange: nil,
            recoveryDTBORange: nil,
            dtbRange: nil
        )
    }

    // MARK: - vendor_boot.img

    public struct VendorBootImage: Sendable, Equatable {
        public var headerVersion: UInt32
        public var pageSize: Int
        public var productName: String
        public var kernelCommandLine: String
        public var vendorRamdiskRange: Range<Int>
        public var dtbRange: Range<Int>?
        /// v4 only: bootconfig appended after the ramdisk table.
        public var bootconfigRange: Range<Int>?
    }

    public static func parseVendorBootImage(_ data: Data) throws -> VendorBootImage {
        var reader = ByteReader(data)
        let magic = try reader.fixedString(8)
        guard magic == vendorBootMagic else { throw Failure.notAVendorBootImage(foundMagic: magic) }

        let headerVersion = try reader.uint32()
        guard (3...4).contains(headerVersion) else {
            throw Failure.unsupportedHeaderVersion(headerVersion, supported: 3...4)
        }

        let pageSize = try validatedPageSize(try reader.uint32())
        _ = try reader.uint32()                    // kernel_addr
        _ = try reader.uint32()                    // ramdisk_addr
        let vendorRamdiskSize = Int(try reader.uint32())
        let commandLine = try reader.fixedString(2048)
        _ = try reader.uint32()                    // tags_addr
        let name = try reader.fixedString(16)
        _ = try reader.uint32()                    // header_size
        let dtbSize = Int(try reader.uint32())
        _ = try reader.uint64()                    // dtb_addr

        var ramdiskTableSize = 0
        var bootconfigSize = 0
        if headerVersion >= 4 {
            ramdiskTableSize = Int(try reader.uint32())
            _ = try reader.uint32()                // vendor_ramdisk_table_entry_num
            _ = try reader.uint32()                // vendor_ramdisk_table_entry_size
            bootconfigSize = Int(try reader.uint32())
        }

        // The vendor boot header is 2112 bytes at version 3 and 2128 at
        // version 4, so with a 2048-byte page it spans *two* pages. Deriving the
        // offset from the bytes actually consumed is what makes this correct for
        // every page size, rather than only for 4096.
        var cursor = roundUpToMultiple(reader.offset, of: pageSize)
        guard let vendorRamdisk = try section("vendor ramdisk", at: &cursor, size: vendorRamdiskSize, pageSize: pageSize, fileSize: data.count) else {
            throw Failure.sectionOutOfBounds(section: "vendor ramdisk", offset: cursor, size: vendorRamdiskSize, fileSize: data.count)
        }
        let dtb = try section("DTB", at: &cursor, size: dtbSize, pageSize: pageSize, fileSize: data.count)
        _ = try section("vendor ramdisk table", at: &cursor, size: ramdiskTableSize, pageSize: pageSize, fileSize: data.count)
        let bootconfig = try section("bootconfig", at: &cursor, size: bootconfigSize, pageSize: pageSize, fileSize: data.count)

        return VendorBootImage(
            headerVersion: headerVersion,
            pageSize: pageSize,
            productName: name,
            kernelCommandLine: commandLine,
            vendorRamdiskRange: vendorRamdisk,
            dtbRange: dtb,
            bootconfigRange: bootconfig
        )
    }

    // MARK: - Helpers

    private static func validatedPageSize(_ raw: UInt32) throws -> Int {
        guard raw >= 512, raw <= 65536, raw & (raw - 1) == 0 else {
            throw Failure.implausiblePageSize(raw)
        }
        return Int(raw)
    }

    /// Locates one page-aligned section and advances the cursor past it.
    /// Returns `nil` for a zero-length section, which is normal and not an error.
    private static func section(
        _ name: String,
        at cursor: inout Int,
        size: Int,
        pageSize: Int,
        fileSize: Int
    ) throws -> Range<Int>? {
        guard size > 0 else { return nil }
        guard size <= fileSize, cursor >= 0, cursor + size <= fileSize else {
            throw Failure.sectionOutOfBounds(section: name, offset: cursor, size: size, fileSize: fileSize)
        }
        let range = cursor..<(cursor + size)
        cursor += roundUpToMultiple(size, of: pageSize)
        return range
    }

    /// Decodes the packed `os_version` word.
    ///
    /// Layout: the top 11 bits hold a `major.minor.patch` triple at 7 bits each,
    /// and the low 21 bits hold a `year.month` pair as `(year - 2000) * 12 + month`.
    static func decodeOSVersion(_ raw: UInt32) -> (version: String?, patchLevel: String?) {
        guard raw != 0 else { return (nil, nil) }
        let versionBits = raw >> 11
        let patchBits = raw & 0x7FF

        let major = (versionBits >> 14) & 0x7F
        let minor = (versionBits >> 7) & 0x7F
        let patch = versionBits & 0x7F
        let year = ((patchBits >> 4) & 0x7F) + 2000
        let month = patchBits & 0xF

        let version = major == 0 && minor == 0 && patch == 0
            ? nil
            : "\(major).\(minor).\(patch)"
        let patchLevel = (1...12).contains(Int(month))
            ? String(format: "%04d-%02d", year, month)
            : nil
        return (version, patchLevel)
    }
}
