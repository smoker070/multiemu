import Darwin
import Foundation

/// Typed, failure-tolerant access to `sysctlbyname`.
///
/// Every accessor returns `nil` for an absent key rather than trapping. That is
/// deliberate: the set of `hw.*` keys differs between Apple Silicon and Intel
/// (`hw.perflevel0.*` and `hw.optional.arm64` exist only on Apple Silicon), and
/// Apple adds keys in new macOS releases. Treating "absent" as "unknown" is what
/// lets one probe binary run correctly on every supported host.
public enum Sysctl {

    /// Reads a NUL-terminated string value, e.g. `machdep.cpu.brand_string`.
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            var length = size
            return sysctlbyname(name, raw.baseAddress, &length, nil, 0)
        }
        guard status == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads a 4- or 8-byte integer value. Returns `nil` for any other width.
    public static func integer(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4:
            var value: Int32 = 0
            var length = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &length, nil, 0) == 0 else { return nil }
            return Int64(value)
        case 8:
            var value: Int64 = 0
            var length = MemoryLayout<Int64>.size
            guard sysctlbyname(name, &value, &length, nil, 0) == 0 else { return nil }
            return value
        default:
            return nil
        }
    }

    /// Reads an integer as an unsigned value, clamping negatives to `nil`.
    public static func unsigned(_ name: String) -> UInt64? {
        guard let value = integer(name), value >= 0 else { return nil }
        return UInt64(value)
    }

    /// Reads a flag-style key. `kern.hv_support` and `hw.optional.*` are `Int32`
    /// booleans in practice.
    public static func flag(_ name: String) -> Bool? {
        integer(name).map { $0 != 0 }
    }

    /// Reads an opaque binary value. Used for structures such as `vm.swapusage`
    /// whose C declaration we decode by hand rather than relying on the Swift
    /// importer exposing the struct.
    public static func raw(_ name: String) -> [UInt8]? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            var length = size
            return sysctlbyname(name, raw.baseAddress, &length, nil, 0)
        }
        guard status == 0 else { return nil }
        return buffer
    }
}
