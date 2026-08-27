import Foundation
import Testing
@testable import MultiemuImages

@Suite("Reading an image's own boot requirements")
struct AndroidImageTraitsTests {

    // MARK: - Filesystem

    private func superblock(f2fs: Bool = false, ext4: Bool = false) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x1000)
        if f2fs { bytes.replaceSubrange(0x400..<0x404, with: [0x10, 0x20, 0xF5, 0xF2]) }
        if ext4 { bytes.replaceSubrange(0x438..<0x43A, with: [0x53, 0xEF]) }
        return Data(bytes)
    }

    @Test("f2fs and ext4 are told apart by their own superblock magic")
    func detectsFilesystems() {
        #expect(AndroidImageTraits.Filesystem.detect(inFirstBytes: superblock(f2fs: true)) == .f2fs)
        #expect(AndroidImageTraits.Filesystem.detect(inFirstBytes: superblock(ext4: true)) == .ext4)
        #expect(AndroidImageTraits.Filesystem.detect(inFirstBytes: superblock()) == .unknown)
    }

    @Test("A truncated read is unknown, not a guess")
    func shortReadIsUnknown() {
        // Reading too few bytes must not silently answer ext4 because the
        // offset happened to fall off the end.
        #expect(AndroidImageTraits.Filesystem.detect(
            inFirstBytes: Data(repeating: 0, count: 0x100)) == .unknown)
    }

    // MARK: - Choosing the fstab

    private let cuttlefishFstabs = ["cf.ext4.cts", "cf.ext4.hctr2", "cf.f2fs.cts", "cf.f2fs.hctr2"]

    @Test("The suffix follows the filesystem the image is actually formatted with")
    func suffixFollowsTheFilesystem() {
        // The half that is decided by evidence. Naming ext4 for an f2fs image
        // means first-stage init cannot mount /data, and that failure is a
        // hang, not an error.
        #expect(AndroidImageTraits.fstabSuffix(from: cuttlefishFstabs, matching: .f2fs) == "cf.f2fs.cts")
        #expect(AndroidImageTraits.fstabSuffix(from: cuttlefishFstabs, matching: .ext4) == "cf.ext4.cts")
    }

    @Test("The encryption mode is a stated preference, and is honoured")
    func encryptionModeIsAPreference() {
        // Nothing in the image chooses between cts and hctr2, so this half is a
        // default rather than a detection — and it must be overridable.
        #expect(AndroidImageTraits.fstabSuffix(
            from: cuttlefishFstabs, matching: .f2fs, preferring: "hctr2") == "cf.f2fs.hctr2")
    }

    @Test("No candidate for the filesystem yields nothing, never a wrong suffix")
    func refusesToGuess() {
        #expect(AndroidImageTraits.fstabSuffix(from: ["cf.ext4.cts"], matching: .f2fs) == nil)
        #expect(AndroidImageTraits.fstabSuffix(from: cuttlefishFstabs, matching: .unknown) == nil)
        #expect(AndroidImageTraits.fstabSuffix(from: [], matching: .f2fs) == nil)
    }

    @Test("A preference that does not exist falls back within the right filesystem")
    func fallsBackInsideTheFilesystem() {
        // Still f2fs — the half that matters is never traded away for the half
        // that is only a preference.
        let suffix = AndroidImageTraits.fstabSuffix(
            from: ["cf.f2fs.hctr2", "cf.ext4.cts"], matching: .f2fs, preferring: "cts")
        #expect(suffix == "cf.f2fs.hctr2")
    }

    // MARK: - Board name

    @Test("The board name is read from the init script that carries it")
    func readsBoardName() {
        let entries = [
            "init.recovery.cutf_cvm.rc", "ueventd.cutf_cvm.rc", "init", "bin/sh",
        ]
        #expect(AndroidImageTraits.hardwareName(fromRamdiskEntries: entries) == "cutf_cvm")
    }

    @Test("An image with no board-specific ueventd is not claimed")
    func doesNotClaimAnUnknownImage() {
        // The detector must decline rather than default to Cuttlefish, or every
        // image installed would be given Cuttlefish's arguments.
        let entries = ["init", "ueventd.rc", "bin/sh", "system/etc/fstab.generic"]
        #expect(AndroidImageTraits.hardwareName(fromRamdiskEntries: entries) == nil)
    }

    @Test("fstab suffixes are collected from wherever they sit in the tree")
    func collectsFstabSuffixes() {
        let entries = [
            "first_stage_ramdisk/system/etc/fstab.cf.f2fs.cts",
            "first_stage_ramdisk/system/etc/fstab.cf.ext4.cts",
            "system/etc/fstab.cf.f2fs.cts",
            "init",
        ]
        #expect(AndroidImageTraits.fstabSuffixes(fromRamdiskEntries: entries)
                == ["cf.ext4.cts", "cf.f2fs.cts"])
    }
}

@Suite("Reading a real ramdisk", .enabled(if: FileManager.default.fileExists(
    atPath: NSHomeDirectory() + "/Library/Application Support/Multiemu/images/cuttlefish-arm64-15660610/derived/ramdisk")))
struct RealRamdiskTests {

    static let ramdisk = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Multiemu/images/cuttlefish-arm64-15660610/derived/ramdisk")

    @Test("The concatenated LZ4 frames decode and yield the whole tree")
    func decodesTheRealRamdisk() throws {
        let names = try AndroidRamdisk.entryNames(at: Self.ramdisk)
        // Both halves must appear. This ramdisk is the vendor ramdisk followed
        // by the generic one, as two back-to-back LZ4 frames; a decoder that
        // stopped at the first frame would return a plausible tree missing
        // exactly the files the detector needs.
        // Both archives, not just the first. An independent decode
        // (`lz4 -d -c` piped through a cpio header walk) counts 559 entries
        // across 2 TRAILER records; anything materially short of that means
        // the walk stopped at the first archive.
        #expect(names.count == 559, "got \(names.count) entries; expected 559 across both archives")
        #expect(names.contains { $0.hasSuffix("ueventd.cutf_cvm.rc") })

        let fstabs = AndroidImageTraits.fstabSuffixes(fromRamdiskEntries: names)
        #expect(fstabs.contains("cf.f2fs.cts"))
        #expect(fstabs.contains("cf.ext4.cts"))
        #expect(AndroidImageTraits.hardwareName(fromRamdiskEntries: names) == "cutf_cvm")
    }

    @Test("The image's own userdata decides the filesystem half")
    func readsFilesystemFromTheRealImage() throws {
        let userdata = Self.ramdisk
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("userdata.img")
        try #require(FileManager.default.fileExists(atPath: userdata.path))

        // A sparse container 8 GiB when expanded; only the first 4 KiB is read.
        #expect(try AndroidImageTraits.filesystem(ofPartitionAt: userdata) == .f2fs)
    }
}

@Suite("The split between image and machine arguments stays complete")
struct KernelArgumentSplitTests {

    /// The command line this project has actually booted Android 17 with.
    static let proven: Set<String> = [
        "console=ttyAMA0", "printk.devkmsg=on", "audit=0", "panic=-1", "cma=0",
        "loop.max_part=7", "init=/init",
        "androidboot.hardware=cutf_cvm", "androidboot.fstab_suffix=cf.f2fs.cts",
        "androidboot.slot_suffix=_a", "androidboot.force_normal_boot=1",
        "androidboot.boot_devices=4010000000.pcie", "androidboot.verifiedbootstate=orange",
        "androidboot.vsock_lights_port=6800", "androidboot.console=hvc1",
        "androidboot.hardware.egl=angle", "androidboot.hardware.vulkan=pastel",
        "androidboot.hardware.gralloc=minigbm", "androidboot.hardware.hwcomposer=drm",
        "androidboot.lcd_density=320", "androidboot.opengles.version=196609",
        "androidboot.vendor.apex.com.android.hardware.gatekeeper=com.android.hardware.gatekeeper.nonsecure.apex",
        "androidboot.vendor.apex.com.android.hardware.keymint=com.android.hardware.keymint.rust_nonsecure.apex",
        "androidboot.vendor.apex.com.android.hardware.graphics.composer=com.android.hardware.graphics.composer.drm_hwcomposer.apex",
        "androidboot.vendor.apex.com.google.emulated.camera.provider.hal=com.google.emulated.camera.provider.hal.apex",
    ]

    @Test("Detected image arguments plus machine arguments equal the line that boots")
    func splitCoversTheProvenCommandLine() {
        // The arguments were split in two: the image knows its board, its fstab
        // and which HALs it ships; the emulator knows which console port it
        // wired, which PCIe address its machine uses, and that it relaxed
        // verified boot. Neither half is complete alone, and this is the test
        // that says so — if either side loses an argument, a guest stalls in
        // second-stage init and reports only that it was slow.
        let detected = AndroidImageTraits.detect(
            ramdiskEntries: [
                "ueventd.cutf_cvm.rc",
                "first_stage_ramdisk/system/etc/fstab.cf.f2fs.cts",
                "first_stage_ramdisk/system/etc/fstab.cf.ext4.cts",
            ],
            userdataFilesystem: .f2fs)

        let machine = Set(AndroidGuestPlan.baseKernelArguments
            + AndroidGuestPlan.machineKernelArguments)
        let produced = Set(detected.kernelArguments).union(machine)

        let missing = Self.proven.subtracting(produced).sorted()
        let extra = produced.subtracting(Self.proven).sorted()
        #expect(missing.isEmpty, "the guest would stall without these")
        #expect(extra.isEmpty, "these reach the kernel and nothing asked for them")
        #expect(produced == Self.proven)
    }

    @Test("The console argument names the port the plan actually wires")
    func consoleArgumentMatchesThePortBank() {
        // These two are set in different places and must agree; if they drift,
        // Android starts a shell on a port nothing is listening to and the
        // quiesce and ADB paths both go silent.
        #expect(AndroidGuestPlan.machineKernelArguments
            .contains("androidboot.console=hvc\(AndroidGuestPlan.shellConsolePort)"))
    }
}

@Suite("cpio walking survives what a byte scan would trip on")
struct CpioWalkTests {

    /// Builds a newc record. `name` is NUL-terminated and the header+name and
    /// the body are each padded to four bytes, as the format requires.
    static func record(name: String, body: Data = Data()) -> Data {
        var out = Data("070701".utf8)
        let fields = [0, 0, 0, 0, 1, 0, body.count, 0, 0, 0, 0, name.utf8.count + 1, 0]
        for value in fields { out.append(Data(String(format: "%08X", value).utf8)) }
        out.append(Data(name.utf8)); out.append(0)
        while out.count % 4 != 0 { out.append(0) }
        out.append(body)
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    @Test("Entries after a trailer are still found")
    func continuesPastATrailer() {
        // Two archives back to back, which is what a real ramdisk is.
        var archive = Self.record(name: "first/file")
        archive += Self.record(name: "TRAILER!!!")
        archive += Self.record(name: "second/file")
        archive += Self.record(name: "TRAILER!!!")

        let names = AndroidRamdisk.cpioEntryNames(archive)
        #expect(names == ["first/file", "second/file"])
    }

    @Test("The literal TRAILER!!! inside a file's contents is not a record")
    func ignoresTrailerInsideAFile() {
        // Measured on the real ramdisk: `TRAILER!!!` appears four times and
        // only two are records. The others live in toybox's cpio writer format
        // string. Walking headers is what tells them apart; a byte scan cannot.
        let body = Data("070701%040X%056X%08XTRAILER!!!%c%c%c%c".utf8)
        var archive = Self.record(name: "bin/toybox", body: body)
        archive += Self.record(name: "TRAILER!!!")

        let names = AndroidRamdisk.cpioEntryNames(archive)
        #expect(names == ["bin/toybox"])
    }
}
