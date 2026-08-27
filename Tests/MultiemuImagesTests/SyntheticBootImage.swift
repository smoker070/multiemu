import Foundation

/// Builds Android boot images byte by byte from the documented C structures.
///
/// Written independently of the parser, field by field against
/// `system/tools/mkbootimg/include/bootimg/bootimg.h`, so that round-tripping is
/// a real check rather than the parser agreeing with itself. The offset
/// assertions in `AndroidBootImageTests` pin the layout separately again.
struct SyntheticBootImage {

    /// Little-endian append helpers.
    struct Writer {
        var data = Data()
        mutating func magic(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        mutating func fixed(_ text: String, _ length: Int) {
            var bytes = Array(text.utf8.prefix(length))
            bytes.append(contentsOf: [UInt8](repeating: 0, count: length - bytes.count))
            data.append(contentsOf: bytes)
        }
        mutating func zeros(_ count: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: count)) }
        mutating func padToMultiple(of alignment: Int) {
            let remainder = data.count % alignment
            if remainder != 0 { zeros(alignment - remainder) }
        }
    }

    /// `boot.img`, header versions 0–4.
    static func bootImage(
        headerVersion: UInt32,
        pageSize: Int = 2048,
        kernel: Data,
        ramdisk: Data? = nil,
        commandLine: String = "console=ttyAMA0",
        osVersionWord: UInt32 = 0,
        productName: String = "multiemu"
    ) -> Data {
        var writer = Writer()
        writer.magic("ANDROID!")

        if headerVersion <= 2 {
            writer.u32(UInt32(kernel.count))          // kernel_size
            writer.u32(0x8000)                        // kernel_addr
            writer.u32(UInt32(ramdisk?.count ?? 0))   // ramdisk_size
            writer.u32(0x1000000)                     // ramdisk_addr
            writer.u32(0)                             // second_size
            writer.u32(0)                             // second_addr
            writer.u32(0x100)                         // tags_addr
            writer.u32(UInt32(pageSize))              // page_size
            writer.u32(headerVersion)                 // header_version  (offset 40)
            writer.u32(osVersionWord)                 // os_version
            writer.fixed(productName, 16)             // name
            writer.fixed(commandLine, 512)            // cmdline
            writer.zeros(32)                          // id[8]
            writer.fixed("", 1024)                    // extra_cmdline
            if headerVersion >= 1 {
                writer.u32(0)                         // recovery_dtbo_size
                writer.u64(0)                         // recovery_dtbo_offset
                writer.u32(1648)                      // header_size
            }
            if headerVersion >= 2 {
                writer.u32(0)                         // dtb_size
                writer.u64(0)                         // dtb_addr
            }
        } else {
            writer.u32(UInt32(kernel.count))          // kernel_size
            writer.u32(UInt32(ramdisk?.count ?? 0))   // ramdisk_size
            writer.u32(osVersionWord)                 // os_version
            writer.u32(headerVersion == 3 ? 1580 : 1584)  // header_size
            writer.zeros(16)                          // reserved[4]
            writer.u32(headerVersion)                 // header_version  (offset 40)
            writer.fixed(commandLine, 1536)           // cmdline
            if headerVersion >= 4 { writer.u32(0) }   // signature_size
        }

        // Version 3 and later fix the page size at 4096.
        let effectivePageSize = headerVersion >= 3 ? 4096 : pageSize
        writer.padToMultiple(of: effectivePageSize)
        writer.data.append(kernel)
        writer.padToMultiple(of: effectivePageSize)
        if let ramdisk {
            writer.data.append(ramdisk)
            writer.padToMultiple(of: effectivePageSize)
        }
        return writer.data
    }

    /// `vendor_boot.img`, header versions 3–4.
    static func vendorBootImage(
        headerVersion: UInt32,
        pageSize: Int = 2048,
        vendorRamdisk: Data,
        deviceTree: Data? = nil,
        commandLine: String = "androidboot.hardware=multiemu",
        productName: String = "multiemu"
    ) -> Data {
        var writer = Writer()
        writer.magic("VNDRBOOT")
        writer.u32(headerVersion)                     // header_version
        writer.u32(UInt32(pageSize))                  // page_size
        writer.u32(0x8000)                            // kernel_addr
        writer.u32(0x1000000)                         // ramdisk_addr
        writer.u32(UInt32(vendorRamdisk.count))       // vendor_ramdisk_size
        writer.fixed(commandLine, 2048)               // cmdline
        writer.u32(0x100)                             // tags_addr
        writer.fixed(productName, 16)                 // name
        writer.u32(2128)                              // header_size
        writer.u32(UInt32(deviceTree?.count ?? 0))    // dtb_size
        writer.u64(0)                                 // dtb_addr
        if headerVersion >= 4 {
            writer.u32(0)                             // vendor_ramdisk_table_size
            writer.u32(0)                             // vendor_ramdisk_table_entry_num
            writer.u32(0)                             // vendor_ramdisk_table_entry_size
            writer.u32(0)                             // bootconfig_size
        }

        writer.padToMultiple(of: pageSize)
        writer.data.append(vendorRamdisk)
        writer.padToMultiple(of: pageSize)
        if let deviceTree {
            writer.data.append(deviceTree)
            writer.padToMultiple(of: pageSize)
        }
        return writer.data
    }

    /// Recognisable filler, so a mis-sliced section is obvious rather than
    /// looking like plausible binary data.
    static func filler(_ marker: UInt8, count: Int) -> Data {
        Data([UInt8](repeating: marker, count: count))
    }
}
