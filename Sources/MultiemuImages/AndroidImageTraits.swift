import Foundation

/// What an installed image says about itself, read from the image.
///
/// **Why this exists.** Every Android image needs a set of `androidboot.*`
/// kernel arguments before it will finish booting, and they are properties of
/// the image, not of the emulator. Installing an image without them produces a
/// guest that stalls in second-stage init until the boot timeout — which is
/// exactly what happened here, and the report that came back was
/// "the emulator is booting very very slowly". It was not slow; it was stuck.
///
/// Everything below is derived from the image where the image can answer, and
/// documented as a default where it cannot. Nothing is inferred from a file
/// name or an identifier the user chose.
public enum AndroidImageTraits {

    /// The filesystem a partition image actually contains.
    public enum Filesystem: String, Sendable, Equatable {
        case ext4
        case f2fs
        case unknown

        /// f2fs writes its superblock magic at 0x400; ext4 writes its own at
        /// 0x438. Both are read from the *expanded* image: Android ships these
        /// as sparse containers, and the magic sits inside.
        public static func detect(inFirstBytes prefix: Data) -> Filesystem {
            func matches(_ offset: Int, _ expected: [UInt8]) -> Bool {
                guard prefix.count >= offset + expected.count else { return false }
                let start = prefix.index(prefix.startIndex, offsetBy: offset)
                let end = prefix.index(start, offsetBy: expected.count)
                return Array(prefix[start..<end]) == expected
            }
            if matches(0x400, [0x10, 0x20, 0xF5, 0xF2]) { return .f2fs }
            if matches(0x438, [0x53, 0xEF]) { return .ext4 }
            return .unknown
        }
    }

    /// How many bytes must be read to see either superblock.
    public static let superblockProbeBytes = 0x1000

    public static func filesystem(ofPartitionAt url: URL) throws -> Filesystem {
        let prefix = try AndroidSparseImage.expandedPrefix(at: url, byteCount: superblockProbeBytes)
        return Filesystem.detect(inFirstBytes: prefix)
    }

    // MARK: - Choosing the fstab

    /// Picks the fstab suffix from the ones the image ships.
    ///
    /// A Cuttlefish ramdisk carries four — `cf.ext4.cts`, `cf.f2fs.cts`,
    /// `cf.f2fs.hctr2`, `cf.ext4.hctr2` — and the image does not say which to
    /// use. Two halves, decided differently:
    ///
    /// * **The filesystem half is decided by evidence.** The shipped
    ///   `userdata.img` is formatted, and `androidboot.fstab_suffix` must name
    ///   the same filesystem or first-stage init cannot mount `/data`. Measured
    ///   on the image this was written against: f2fs.
    /// * **The encryption half is a documented default.** `cts` and `hctr2` are
    ///   filename-encryption modes; nothing in the image chooses between them.
    ///   `cts` is preferred because it is the one this project has booted.
    ///
    /// Returns `nil` rather than guessing when no candidate matches the
    /// filesystem — a wrong suffix does not fail loudly, it hangs.
    public static func fstabSuffix(
        from available: [String],
        matching filesystem: Filesystem,
        preferring encryptionMode: String = "cts"
    ) -> String? {
        guard filesystem != .unknown else { return nil }
        let matching = available.filter { $0.contains(".\(filesystem.rawValue).") }
        guard !matching.isEmpty else { return nil }
        return matching.first { $0.hasSuffix(".\(encryptionMode)") } ?? matching.sorted().first
    }

    // MARK: - The whole detection

    /// What an image turned out to be, and the arguments that follow from it.
    public struct Detection: Sendable, Equatable {
        public var board: String?
        public var fstabSuffix: String?
        public var filesystem: Filesystem
        public var availableFstabSuffixes: [String]
        /// Arguments the **image** determines. Host-side arguments — which
        /// console port carries the shell, which PCIe address the machine puts
        /// the disk on, whether verified boot was relaxed — are not here: those
        /// are properties of the emulator, and writing them into an image's
        /// manifest would make the image lie about the machine.
        public var kernelArguments: [String]
        /// How the image expects its partitions presented, when that follows
        /// from the board. `nil` means "not determined" — the caller keeps
        /// whatever it had rather than being handed a guess.
        public var partitionLayout: AndroidGuestPlan.PartitionLayout?
        /// What was read, in the order it was read, so a wrong answer can be
        /// traced to the thing that produced it.
        public var evidence: [String]

        public var isRecognised: Bool { board != nil && fstabSuffix != nil }
    }

    /// Cuttlefish selects HAL implementations by kernel argument, and the
    /// choices are properties of what the image contains.
    ///
    /// Taken from the command line this project booted the image with, and
    /// emitted only for a board recognised as Cuttlefish — an unknown board
    /// gets nothing beyond what was actually derived, because guessing HAL
    /// variants for an image nobody has booted is how a boot hangs with no
    /// explanation.
    static let cuttlefishArguments = [
        "androidboot.hardware.egl=angle",
        "androidboot.hardware.vulkan=pastel",
        "androidboot.hardware.gralloc=minigbm",
        "androidboot.hardware.hwcomposer=drm",
        "androidboot.opengles.version=196609",
        "androidboot.vendor.apex.com.android.hardware.gatekeeper=com.android.hardware.gatekeeper.nonsecure.apex",
        "androidboot.vendor.apex.com.android.hardware.keymint=com.android.hardware.keymint.rust_nonsecure.apex",
        "androidboot.vendor.apex.com.android.hardware.graphics.composer=com.android.hardware.graphics.composer.drm_hwcomposer.apex",
        "androidboot.vendor.apex.com.google.emulated.camera.provider.hal=com.google.emulated.camera.provider.hal.apex",
    ]

    /// Boards this project has actually booted and therefore has arguments for.
    static let knownCuttlefishBoards: Set<String> = ["cutf_cvm"]

    public static func detect(
        ramdiskEntries: [String],
        userdataFilesystem: Filesystem,
        preferringEncryptionMode encryptionMode: String = "cts"
    ) -> Detection {
        var evidence: [String] = []
        let board = hardwareName(fromRamdiskEntries: ramdiskEntries)
        if let board {
            evidence.append("board `\(board)` from ueventd.\(board).rc in the ramdisk")
        } else {
            evidence.append("no board-specific ueventd.*.rc — the board could not be identified")
        }

        let suffixes = fstabSuffixes(fromRamdiskEntries: ramdiskEntries)
        evidence.append(suffixes.isEmpty
            ? "no fstab.* in the ramdisk"
            : "fstab variants: \(suffixes.joined(separator: ", "))")
        evidence.append("userdata is formatted \(userdataFilesystem.rawValue)")

        let suffix = fstabSuffix(from: suffixes, matching: userdataFilesystem,
                                 preferring: encryptionMode)
        if let suffix {
            evidence.append("chose \(suffix): it is the \(userdataFilesystem.rawValue) "
                + "variant, and `\(encryptionMode)` is the preferred encryption mode")
        } else {
            evidence.append("no fstab variant matches the filesystem — none chosen")
        }

        var arguments: [String] = []
        if let board { arguments.append("androidboot.hardware=\(board)") }
        if let suffix { arguments.append("androidboot.fstab_suffix=\(suffix)") }
        if let board, knownCuttlefishBoards.contains(board) {
            arguments += cuttlefishArguments
            evidence.append("`\(board)` is a board this project has booted, so its HAL "
                + "selections were added")
        } else if board != nil {
            evidence.append("no HAL selections added: this board is not one this project "
                + "has booted, and inventing them would hang the guest silently")
        }

        var layout: AndroidGuestPlan.PartitionLayout?
        if let board, knownCuttlefishBoards.contains(board) {
            // Cuttlefish mounts through /dev/block/by-name/…, which only
            // exists on one GPT disk. Presented as separate block devices, its
            // first-stage init finds nothing to mount and the kernel panics
            // with `Attempted to kill init!` about ten seconds in.
            layout = .compositeGPTDisk
            evidence.append("needs one GPT disk: `\(board)` mounts by partition name")
        }

        return Detection(board: board, fstabSuffix: suffix, filesystem: userdataFilesystem,
                         availableFstabSuffixes: suffixes, kernelArguments: arguments,
                         partitionLayout: layout, evidence: evidence)
    }

    /// Detects against an installed, unpacked image.
    public static func detect(
        ramdiskAt ramdisk: URL, userdataAt userdata: URL
    ) throws -> Detection {
        let entries = try AndroidRamdisk.entryNames(at: ramdisk)
        return detect(ramdiskEntries: entries,
                      userdataFilesystem: try filesystem(ofPartitionAt: userdata))
    }

    // MARK: - Recognising the board

    /// Cuttlefish names its init scripts after the board, so the board name is
    /// in the file name: `init.recovery.cutf_cvm.rc`, `ueventd.cutf_cvm.rc`.
    ///
    /// That is the most specific signal available. It is not a guess from the
    /// image identifier, which the user chose, or from a partition layout,
    /// which several boards share.
    public static func hardwareName(fromRamdiskEntries entries: [String]) -> String? {
        for entry in entries {
            let name = (entry as NSString).lastPathComponent
            guard name.hasPrefix("ueventd."), name.hasSuffix(".rc") else { continue }
            let board = String(name.dropFirst("ueventd.".count).dropLast(".rc".count))
            if !board.isEmpty, board != "rc" { return board }
        }
        return nil
    }

    /// Every `fstab.*` the ramdisk carries, as suffixes.
    public static func fstabSuffixes(fromRamdiskEntries entries: [String]) -> [String] {
        var found: Set<String> = []
        for entry in entries {
            let name = (entry as NSString).lastPathComponent
            guard name.hasPrefix("fstab."), name.count > "fstab.".count else { continue }
            found.insert(String(name.dropFirst("fstab.".count)))
        }
        return found.sorted()
    }
}
