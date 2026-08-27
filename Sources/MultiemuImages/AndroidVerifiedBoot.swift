import Foundation
import MultiemuSupport

/// Android Verified Boot metadata, and the one modification Multiemu makes to
/// it.
///
/// AVB is a chain of trust: `vbmeta` holds hashes and a signature covering the
/// other partitions, and `fs_mgr` refuses to mount anything that does not
/// verify against a key it trusts. A device flashed by its manufacturer has
/// that key; an emulator booting an AOSP test image does not, and the boot
/// stops at
///
///     [libfs_avb] Found unknown public key used to sign /system
///     init: Failed to mount /system
///
/// AVB itself provides the way out: two flags in the `vbmeta` header that say
/// verification is deliberately off. This is what `avbtool disable_verification`
/// sets, and it is what a locally built or `userdebug` image expects.
///
/// **This weakens a security boundary and is therefore opt-in, never a
/// default.** Setting it means the guest will mount partitions this project has
/// not verified the provenance of. That is defensible for an AOSP image the
/// user downloaded and whose SHA-256 the image store recorded; it is not
/// defensible silently.
///
/// Layout from AOSP's `libavb/avb_vbmeta_image.h`. The header is big-endian.
public enum AndroidVerifiedBoot {

    public static let magic = Data("AVB0".utf8)
    /// Byte offset of the flags word within `AvbVBMetaImageHeader`.
    static let flagsOffset = 120

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// dm-verity is not set up for hashtree-protected partitions.
        public static let hashtreeDisabled = Flags(rawValue: 1)
        /// vbmeta itself is not verified.
        public static let verificationDisabled = Flags(rawValue: 2)

        /// Both, which is what booting an unsigned image needs.
        public static let relaxed: Flags = [.hashtreeDisabled, .verificationDisabled]

        public var description: String {
            var names: [String] = []
            if contains(.hashtreeDisabled) { names.append("hashtree-disabled") }
            if contains(.verificationDisabled) { names.append("verification-disabled") }
            return names.isEmpty ? "none" : names.joined(separator: ", ")
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notVBMeta(path: String)
        case truncated(path: String, size: Int)

        public var description: String {
            switch self {
            case let .notVBMeta(path):
                return "\(path) is not an AVB vbmeta image."
            case let .truncated(path, size):
                return "\(path) is only \(size) bytes, too short to hold a vbmeta header."
            }
        }
    }

    /// True when this file is a vbmeta image.
    public static func isVBMeta(_ data: Data) -> Bool {
        data.count >= flagsOffset + 4 && data.prefix(4) == magic
    }

    public static func readFlags(_ data: Data) throws -> Flags {
        guard data.count >= flagsOffset + 4 else {
            throw Failure.truncated(path: "<data>", size: data.count)
        }
        guard data.prefix(4) == magic else { throw Failure.notVBMeta(path: "<data>") }
        let raw = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: flagsOffset, as: UInt32.self)
        }
        return Flags(rawValue: UInt32(bigEndian: raw))
    }

    /// Returns a copy with the given flags set.
    ///
    /// A copy rather than an edit in place: the installed image is the thing
    /// whose SHA-256 the manifest recorded and verifies before every boot, so
    /// it must not be modified. Only the composite disk built from it carries
    /// the relaxed flags.
    public static func settingFlags(_ flags: Flags, in data: Data) throws -> Data {
        guard data.count >= flagsOffset + 4 else {
            throw Failure.truncated(path: "<data>", size: data.count)
        }
        guard data.prefix(4) == magic else { throw Failure.notVBMeta(path: "<data>") }

        var copy = data
        let existing = try readFlags(data)
        let combined = existing.union(flags).rawValue.bigEndian
        withUnsafeBytes(of: combined) { bytes in
            copy.replaceSubrange(
                copy.startIndex + flagsOffset ..< copy.startIndex + flagsOffset + 4,
                with: bytes)
        }
        return copy
    }
}
