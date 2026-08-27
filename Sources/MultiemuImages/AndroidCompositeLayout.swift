import Foundation
import MultiemuSupport

/// Maps an installed image set onto GPT partition names Android expects.
///
/// The names below follow Cuttlefish's disk layout. They are **provisional**:
/// the authoritative list is whatever the image's own first-stage init looks
/// for, and that is read off a real boot console, not guessed. See
/// `docs/VERIFY.md` → `ANDROID-PARTITION-LAYOUT`. Keeping the mapping in one
/// table means correcting it is a data change, not a code change.
public enum AndroidCompositeLayout {

    /// Slot suffix for A/B devices. Cuttlefish images are A/B and their init
    /// looks for `<name>_a` when `androidboot.slot_suffix=_a`.
    public static let defaultSlotSuffix = "_a"

    /// Partition name for a role, or `nil` when the role is not a partition.
    /// The partition a given FILE becomes.
    ///
    /// A repeatable role takes its name from the file, because naming it from
    /// the role would give every vbmeta the same name — and the caller drops
    /// duplicates, so the extra partitions would vanish without a word.
    public static func partitionName(for file: ManifestFile, slotSuffix: String) -> String? {
        guard file.role.allowsMultipleFiles else {
            return partitionName(for: file.role, slotSuffix: slotSuffix)
        }
        // vbmeta partitions are slotted, like the images they authenticate.
        return "\(file.effectivePartitionName)\(slotSuffix)"
    }

    public static func partitionName(for role: PartitionRole, slotSuffix: String) -> String? {
        switch role {
        case .bootImage: return "boot\(slotSuffix)"
        case .vendorBootImage: return "vendor_boot\(slotSuffix)"
        // init_boot carries the generic ramdisk from Android 13 onward. It is
        // passed to the kernel as the initramfs AND must exist as a partition:
        // first-stage init looks it up by name and waits ten seconds for a
        // uevent that never comes, then falls through to recovery.
        case .ramdisk: return "init_boot\(slotSuffix)"
        case .superImage: return "super"
        case .system: return "system\(slotSuffix)"
        case .systemExt: return "system_ext\(slotSuffix)"
        case .vendor: return "vendor\(slotSuffix)"
        case .product: return "product\(slotSuffix)"
        case .vbmeta: return "vbmeta\(slotSuffix)"
        case .userdata: return "userdata"
        case .metadata: return "metadata"
        case .cache: return "cache"
        default: return nil
        }
    }

    /// Partitions Android needs that no image file supplies, created empty.
    ///
    /// `misc` in particular must exist: Android's bootloader-message handling
    /// writes to it, and a missing `misc` is a confusing early boot failure.
    ///
    /// `frp` holds the factory-reset-protection block and is just as load
    /// bearing, in a way that is far harder to read from the symptom.
    /// `PersistentDataBlockService` opens the partition named by `ro.frp.pst`
    /// on a worker thread; with no such partition the thread never signals, and
    /// `onBootPhase(500)` throws `PersistentDataBlockService init timeout`
    /// after ten seconds. That exception is fatal to `system_server`, so the
    /// guest reaches a full framework, dies, and restarts forever — with
    /// nothing anywhere naming the missing partition.
    public static let syntheticPartitions: [(name: String, sizeBytes: UInt64)] = [
        ("misc", 1 * ByteCount.miB),
        ("frp", 1 * ByteCount.miB),
    ]

    /// Builds the partition list for a composite disk.
    public static func partitions(
        manifest: ImageManifest,
        store: ImageStore,
        slotSuffix: String = defaultSlotSuffix,
        userdataSizeBytes: UInt64,
        metadataSizeBytes: UInt64 = 16 * ByteCount.miB
    ) -> [CompositeDiskBuilder.Partition] {
        var partitions: [CompositeDiskBuilder.Partition] = []
        var declaredNames = Set<String>()

        for file in manifest.files {
            guard let name = partitionName(for: file, slotSuffix: slotSuffix) else { continue }
            guard declaredNames.insert(name).inserted else { continue }
            // userdata and metadata come from the image only if it ships them;
            // otherwise they are created empty below at the configured size.
            let url = store.url(of: file, in: manifest.imageIdentifier)
            partitions.append(.init(name: name, sourceURL: url))
        }

        if declaredNames.insert("userdata").inserted {
            partitions.append(.init(name: "userdata", sizeBytes: userdataSizeBytes))
        }
        if declaredNames.insert("metadata").inserted {
            partitions.append(.init(name: "metadata", sizeBytes: metadataSizeBytes))
        }
        for synthetic in syntheticPartitions where declaredNames.insert(synthetic.name).inserted {
            partitions.append(.init(name: synthetic.name, sizeBytes: synthetic.sizeBytes))
        }
        return partitions
    }
}
