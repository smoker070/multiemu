import Foundation
import Testing
@testable import MultiemuImages

@Suite("Android boot image")
struct AndroidBootImageTests {

    // MARK: Layout pinning

    @Test("header_version sits at offset 40 in every supported header family")
    func headerVersionOffsetIsStable() {
        // Version-first parsing is only possible because both header families
        // place header_version at the same offset. If that ever stops being
        // true, the parser silently reads a different field — so it is asserted
        // directly against the bytes rather than inferred from behaviour.
        for version: UInt32 in [0, 1, 2, 3, 4] {
            let image = SyntheticBootImage.bootImage(
                headerVersion: version,
                kernel: SyntheticBootImage.filler(0xAA, count: 64)
            )
            let word = image.subdata(in: 40..<44).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            }
            #expect(word == version, "header_version for v\(version) was not at offset 40")
        }
    }

    @Test("Magic occupies the first eight bytes")
    func magicOffset() {
        let boot = SyntheticBootImage.bootImage(headerVersion: 4, kernel: SyntheticBootImage.filler(1, count: 16))
        #expect(String(decoding: boot.prefix(8), as: UTF8.self) == "ANDROID!")
        let vendor = SyntheticBootImage.vendorBootImage(headerVersion: 4, vendorRamdisk: SyntheticBootImage.filler(2, count: 16))
        #expect(String(decoding: vendor.prefix(8), as: UTF8.self) == "VNDRBOOT")
    }

    // MARK: Round trips

    @Test("Every supported boot header version round-trips kernel and ramdisk bytes", arguments: [UInt32(0), 1, 2, 3, 4])
    func roundTripAllVersions(version: UInt32) throws {
        let kernel = SyntheticBootImage.filler(0xA1, count: 5000)
        let ramdisk = SyntheticBootImage.filler(0xB1, count: 3000)
        let data = SyntheticBootImage.bootImage(
            headerVersion: version,
            kernel: kernel,
            ramdisk: ramdisk,
            commandLine: "console=ttyAMA0 androidboot.hardware=multiemu"
        )

        let parsed = try AndroidBootImage.parseBootImage(data)
        #expect(parsed.headerVersion == version)
        let kernelRange = try #require(parsed.kernelRange)
        #expect(Data(data[kernelRange]) == kernel)
        let ramdiskRange = try #require(parsed.ramdiskRange)
        #expect(Data(data[ramdiskRange]) == ramdisk)
        #expect(parsed.kernelCommandLine.contains("androidboot.hardware=multiemu"))
        #expect(parsed.pageSize == (version >= 3 ? 4096 : 2048))
    }

    @Test("An image with no ramdisk parses, reporting none")
    func kernelOnlyImage() throws {
        let kernel = SyntheticBootImage.filler(0x11, count: 1024)
        let parsed = try AndroidBootImage.parseBootImage(
            SyntheticBootImage.bootImage(headerVersion: 2, kernel: kernel)
        )
        #expect(parsed.ramdiskRange == nil)
        #expect(!parsed.hasRamdisk)
    }

    @Test("Sections are located at page boundaries, not packed")
    func sectionsArePageAligned() throws {
        let kernel = SyntheticBootImage.filler(0x22, count: 100)   // far smaller than a page
        let ramdisk = SyntheticBootImage.filler(0x33, count: 100)
        let data = SyntheticBootImage.bootImage(
            headerVersion: 2, pageSize: 2048, kernel: kernel, ramdisk: ramdisk
        )
        let parsed = try AndroidBootImage.parseBootImage(data)
        #expect(parsed.kernelRange?.lowerBound == 2048)
        // Packed rather than aligned would put the ramdisk at 2148.
        #expect(parsed.ramdiskRange?.lowerBound == 4096)
    }

    // MARK: vendor_boot

    @Test("vendor_boot v3 and v4 round-trip the vendor ramdisk", arguments: [UInt32(3), 4])
    func vendorBootRoundTrip(version: UInt32) throws {
        let ramdisk = SyntheticBootImage.filler(0x55, count: 4096)
        let dtb = SyntheticBootImage.filler(0x66, count: 512)
        let data = SyntheticBootImage.vendorBootImage(
            headerVersion: version, vendorRamdisk: ramdisk, deviceTree: dtb,
            commandLine: "androidboot.hardware=cutf_cvm"
        )
        let parsed = try AndroidBootImage.parseVendorBootImage(data)
        #expect(parsed.headerVersion == version)
        #expect(Data(data[parsed.vendorRamdiskRange]) == ramdisk)
        let dtbRange = try #require(parsed.dtbRange)
        #expect(Data(data[dtbRange]) == dtb)
        #expect(parsed.kernelCommandLine == "androidboot.hardware=cutf_cvm")
    }

    // MARK: Rejection

    @Test("A file without the boot magic is rejected by name")
    func rejectsWrongMagic() {
        var data = SyntheticBootImage.bootImage(headerVersion: 2, kernel: SyntheticBootImage.filler(1, count: 64))
        data.replaceSubrange(0..<8, with: Array("NOTBOOT!".utf8))
        #expect(throws: AndroidBootImage.Failure.self) { try AndroidBootImage.parseBootImage(data) }
    }

    @Test("A boot image is not accepted as a vendor boot image")
    func doesNotConfuseContainers() {
        let boot = SyntheticBootImage.bootImage(headerVersion: 4, kernel: SyntheticBootImage.filler(1, count: 64))
        #expect(throws: AndroidBootImage.Failure.self) { try AndroidBootImage.parseVendorBootImage(boot) }
    }

    @Test("An unsupported header version is rejected rather than guessed at")
    func rejectsUnsupportedVersion() {
        let data = SyntheticBootImage.bootImage(headerVersion: 9, kernel: SyntheticBootImage.filler(1, count: 64))
        #expect(throws: AndroidBootImage.Failure.self) { try AndroidBootImage.parseBootImage(data) }
    }

    @Test("An implausible page size is rejected")
    func rejectsBadPageSize() {
        // 1000 is neither a power of two nor a real page size.
        var data = SyntheticBootImage.bootImage(headerVersion: 0, kernel: SyntheticBootImage.filler(1, count: 64))
        let badPageSize = UInt32(1000).littleEndian
        withUnsafeBytes(of: badPageSize) { data.replaceSubrange(36..<40, with: $0) }
        #expect(throws: AndroidBootImage.Failure.self) { try AndroidBootImage.parseBootImage(data) }
    }

    @Test("A section claiming more bytes than the file holds is rejected")
    func rejectsOutOfBoundsSection() {
        var data = SyntheticBootImage.bootImage(headerVersion: 2, kernel: SyntheticBootImage.filler(1, count: 1024))
        // Claim a 1 GiB kernel inside a few-KiB file.
        let hugeSize = UInt32(1 << 30).littleEndian
        withUnsafeBytes(of: hugeSize) { data.replaceSubrange(8..<12, with: $0) }
        #expect(throws: AndroidBootImage.Failure.self) { try AndroidBootImage.parseBootImage(data) }
    }

    @Test("A truncated header is rejected rather than read out of bounds")
    func rejectsTruncatedHeader() {
        let data = SyntheticBootImage.bootImage(headerVersion: 4, kernel: SyntheticBootImage.filler(1, count: 64))
        for length in [0, 4, 8, 20, 39] {
            #expect(throws: (any Error).self) {
                try AndroidBootImage.parseBootImage(data.prefix(length))
            }
        }
    }

    @Test("An image declaring a zero-length kernel is rejected")
    func rejectsEmptyKernel() {
        var data = SyntheticBootImage.bootImage(headerVersion: 3, kernel: SyntheticBootImage.filler(1, count: 4096))
        withUnsafeBytes(of: UInt32(0).littleEndian) { data.replaceSubrange(8..<12, with: $0) }
        #expect(throws: AndroidBootImage.Failure.self) { try AndroidBootImage.parseBootImage(data) }
    }

    // MARK: os_version decoding

    @Test("The packed os_version word decodes to a release and a patch level")
    func decodesOSVersion() {
        // Android 14.0.0, security patch 2024-06.
        let version: UInt32 = (14 << 14) | (0 << 7) | 0
        let patch: UInt32 = UInt32((2024 - 2000) << 4) | 6
        let packed = (version << 11) | patch
        let decoded = AndroidBootImage.decodeOSVersion(packed)
        #expect(decoded.version == "14.0.0")
        #expect(decoded.patchLevel == "2024-06")
    }

    @Test("A zero os_version word decodes to nothing rather than to 0.0.0")
    func decodesAbsentOSVersion() {
        let decoded = AndroidBootImage.decodeOSVersion(0)
        #expect(decoded.version == nil)
        #expect(decoded.patchLevel == nil)
    }

    // MARK: Alignment helper

    @Test("Page rounding matches the layout rule")
    func rounding() {
        #expect(roundUpToMultiple(0, of: 2048) == 0)
        #expect(roundUpToMultiple(1, of: 2048) == 2048)
        #expect(roundUpToMultiple(2048, of: 2048) == 2048)
        #expect(roundUpToMultiple(2049, of: 2048) == 4096)
    }
}

@Suite("Kernel-less boot images")
struct InitBootImageTests {

    /// Android 13 moved the generic ramdisk into its own `init_boot.img`, which
    /// carries a ramdisk and no kernel. Rejecting it left the guest with an
    /// initramfs of vendor files and no `/init`.
    @Test("A boot image with no kernel parses when a kernel is not required")
    func kernelLessImageParses() throws {
        let ramdisk = SyntheticBootImage.filler(0xD1, count: 3072)
        let data = SyntheticBootImage.bootImage(
            headerVersion: 4, pageSize: 4096, kernel: Data(), ramdisk: ramdisk)

        // The default still insists, because every other boot image has one.
        #expect(throws: AndroidBootImage.Failure.self) {
            try AndroidBootImage.parseBootImage(data)
        }

        let parsed = try AndroidBootImage.parseBootImage(data, requiresKernel: false)
        #expect(parsed.kernelRange == nil)
        let ramdiskRange = try #require(parsed.ramdiskRange)
        #expect(Data(data[ramdiskRange]) == ramdisk)
    }
}
