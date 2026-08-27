import Foundation
import Testing
@testable import MultiemuImages

@Suite("Android Verified Boot")
struct AndroidVerifiedBootTests {

    /// A vbmeta header is 256 bytes; only the magic and the flags word matter
    /// here, so the rest is filler that must survive untouched.
    private func vbmetaImage(flags: UInt32 = 0, trailing: Int = 0) -> Data {
        var data = Data("AVB0".utf8)
        data += Data((4..<AndroidVerifiedBoot.flagsOffset).map { UInt8($0 % 251) })
        data += withUnsafeBytes(of: flags.bigEndian) { Data($0) }
        data += Data(repeating: 0xC3, count: 256 - AndroidVerifiedBoot.flagsOffset - 4 + trailing)
        return data
    }

    // MARK: Recognition

    @Test("A vbmeta image is recognised by its magic")
    func recognisesVBMeta() {
        #expect(AndroidVerifiedBoot.isVBMeta(vbmetaImage()))
    }

    @Test("Something that is not vbmeta is not mistaken for it")
    func rejectsOtherImages() {
        #expect(AndroidVerifiedBoot.isVBMeta(Data(repeating: 0, count: 4096)) == false)
        #expect(AndroidVerifiedBoot.isVBMeta(Data("ANDROID!".utf8)) == false)
    }

    @Test("A file too short to hold the flags word is not treated as vbmeta")
    func rejectsTruncated() {
        let stub = Data("AVB0".utf8) + Data(repeating: 0, count: 8)
        #expect(AndroidVerifiedBoot.isVBMeta(stub) == false)
        #expect(throws: AndroidVerifiedBoot.Failure.self) {
            _ = try AndroidVerifiedBoot.readFlags(stub)
        }
    }

    @Test("Reading flags from a non-vbmeta image throws rather than returning a number")
    func readingNonVBMetaThrows() {
        let notVBMeta = Data(repeating: 0x42, count: 256)
        #expect(throws: AndroidVerifiedBoot.Failure.self) {
            _ = try AndroidVerifiedBoot.readFlags(notVBMeta)
        }
    }

    // MARK: Flags

    @Test("Flags are read from the big-endian word at offset 120")
    func readsFlagsBigEndian() throws {
        #expect(try AndroidVerifiedBoot.readFlags(vbmetaImage(flags: 0)).rawValue == 0)
        #expect(try AndroidVerifiedBoot.readFlags(vbmetaImage(flags: 1))
            .contains(.hashtreeDisabled))
        #expect(try AndroidVerifiedBoot.readFlags(vbmetaImage(flags: 2))
            .contains(.verificationDisabled))

        // Byte order is the point: 0x00000001 big-endian puts the 1 last.
        let image = vbmetaImage(flags: 1)
        #expect(Array(image[AndroidVerifiedBoot.flagsOffset..<(AndroidVerifiedBoot.flagsOffset + 4)])
            == [0, 0, 0, 1])
    }

    @Test("Relaxing sets both the hashtree and verification flags")
    func relaxingSetsBothFlags() throws {
        let relaxed = try AndroidVerifiedBoot.settingFlags(.relaxed, in: vbmetaImage())
        let flags = try AndroidVerifiedBoot.readFlags(relaxed)
        #expect(flags.contains(.hashtreeDisabled))
        #expect(flags.contains(.verificationDisabled))
        #expect(flags.rawValue == 3)
    }

    @Test("Setting flags preserves flags that were already there")
    func preservesExistingFlags() throws {
        // 0x40 is not a flag this type names; it must survive anyway rather
        // than being clobbered by a blind overwrite.
        let relaxed = try AndroidVerifiedBoot.settingFlags(.hashtreeDisabled, in: vbmetaImage(flags: 0x40))
        #expect(try AndroidVerifiedBoot.readFlags(relaxed).rawValue == 0x41)
    }

    @Test("Only the four flag bytes change; the rest of the image is untouched")
    func changesOnlyTheFlagsWord() throws {
        let original = vbmetaImage(trailing: 512)
        let relaxed = try AndroidVerifiedBoot.settingFlags(.relaxed, in: original)

        #expect(relaxed.count == original.count)
        let offset = AndroidVerifiedBoot.flagsOffset
        #expect(relaxed.prefix(offset) == original.prefix(offset))
        #expect(relaxed.dropFirst(offset + 4) == original.dropFirst(offset + 4))
    }

    @Test("The original image is returned unmodified, since the manifest verifies its digest")
    func doesNotMutateTheSource() throws {
        let original = vbmetaImage()
        let copy = original
        _ = try AndroidVerifiedBoot.settingFlags(.relaxed, in: original)
        #expect(original == copy)
        #expect(try AndroidVerifiedBoot.readFlags(original).rawValue == 0)
    }

    @Test("Relaxing is idempotent")
    func relaxingTwiceIsTheSameAsOnce() throws {
        let once = try AndroidVerifiedBoot.settingFlags(.relaxed, in: vbmetaImage())
        let twice = try AndroidVerifiedBoot.settingFlags(.relaxed, in: once)
        #expect(once == twice)
    }

    @Test("Refusing to relax something that is not vbmeta")
    func refusesNonVBMeta() {
        #expect(throws: AndroidVerifiedBoot.Failure.self) {
            _ = try AndroidVerifiedBoot.settingFlags(.relaxed, in: Data(repeating: 0x11, count: 256))
        }
    }

    @Test("Flags describe themselves for the report the operator sees")
    func flagsDescribeThemselves() {
        #expect(AndroidVerifiedBoot.Flags([]).description == "none")
        #expect(AndroidVerifiedBoot.Flags.hashtreeDisabled.description == "hashtree-disabled")
        #expect(AndroidVerifiedBoot.Flags.relaxed.description
            == "hashtree-disabled, verification-disabled")
    }
}
