import Darwin
import Foundation
import Metal
import MultiemuSupport
import Security

// MARK: - Operating system

enum OperatingSystemProbe {
    static func collect() -> OperatingSystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return OperatingSystemInfo(
            productVersion: Sysctl.string("kern.osproductversion")
                ?? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            buildVersion: Sysctl.string("kern.osversion") ?? "unknown",
            majorVersion: version.majorVersion,
            minorVersion: version.minorVersion,
            patchVersion: version.patchVersion
        )
    }
}

// MARK: - CPU

enum CPUProbe {
    static func collect() -> CPUInfo {
        let isAppleSilicon = Sysctl.flag("hw.optional.arm64") ?? false
        let architecture: HostArchitecture
        if isAppleSilicon {
            architecture = .appleSilicon
        } else if Sysctl.string("machdep.cpu.brand_string") != nil {
            // Every Intel Mac exposes machdep.cpu.brand_string; Apple Silicon
            // exposes it too, so this branch is only reached when hw.optional.arm64
            // is absent or zero, i.e. a genuine x86_64 host.
            architecture = .intel
        } else {
            architecture = .unknown
        }

        return CPUInfo(
            architecture: architecture,
            brand: Sysctl.string("machdep.cpu.brand_string") ?? "unknown",
            machineModel: Sysctl.string("hw.model") ?? "unknown",
            logicalCores: Int(Sysctl.integer("hw.logicalcpu") ?? 0),
            physicalCores: Int(Sysctl.integer("hw.physicalcpu") ?? 0),
            performanceCores: Sysctl.integer("hw.perflevel0.physicalcpu").map(Int.init),
            efficiencyCores: Sysctl.integer("hw.perflevel1.physicalcpu").map(Int.init),
            cacheLineSizeBytes: Sysctl.integer("hw.cachelinesize").map(Int.init),
            cpuFamily: Sysctl.integer("hw.cpufamily")
        )
    }
}

// MARK: - Memory

enum MemoryProbe {
    static func collect() -> MemoryInfo {
        let physical = Sysctl.unsigned("hw.memsize") ?? 0
        let pageSize = Sysctl.unsigned("hw.pagesize") ?? 4096

        var free: UInt64 = 0
        var inactive: UInt64 = 0
        var wired: UInt64 = 0
        var compressed: UInt64 = 0
        var purgeable: UInt64 = 0
        var speculative: UInt64 = 0

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        if result == KERN_SUCCESS {
            free = UInt64(stats.free_count) * pageSize
            inactive = UInt64(stats.inactive_count) * pageSize
            wired = UInt64(stats.wire_count) * pageSize
            compressed = UInt64(stats.compressor_page_count) * pageSize
            purgeable = UInt64(stats.purgeable_count) * pageSize
            speculative = UInt64(stats.speculative_count) * pageSize
        }

        // macOS reports speculative pages inside free_count. Subtract them, then
        // add the pages the kernel can reclaim without user-visible cost
        // (inactive + purgeable). This mirrors how Activity Monitor derives its
        // "memory available" figure and is documented as an estimate, not a
        // guarantee — see ResourceValidator for how it is actually used.
        let reclaimable = free.subtractingReportingOverflow(speculative).partialValue
        let estimatedAvailable = reclaimable &+ inactive &+ purgeable

        let swap = swapUsage()

        return MemoryInfo(
            physicalBytes: physical,
            pageSizeBytes: pageSize,
            estimatedAvailableBytes: min(estimatedAvailable, physical),
            freeBytes: free,
            inactiveBytes: inactive,
            wiredBytes: wired,
            compressedBytes: compressed,
            swapTotalBytes: swap?.total,
            swapUsedBytes: swap?.used
        )
    }

    /// Decodes `vm.swapusage` by hand.
    ///
    /// `struct xsw_usage` begins with three `uint64_t` fields (total, avail,
    /// used). Reading raw bytes avoids depending on the Swift importer exposing
    /// the C struct, which is not guaranteed across SDK versions.
    private static func swapUsage() -> (total: UInt64, used: UInt64)? {
        guard let bytes = Sysctl.raw("vm.swapusage"), bytes.count >= 24 else { return nil }
        func u64(at offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
            }
            return value
        }
        return (total: u64(at: 0), used: u64(at: 16))
    }
}

// MARK: - Storage

enum StorageProbe {
    /// Where Multiemu keeps virtual devices, images and snapshots.
    /// Application Support is correct for large, user-owned, non-regenerable
    /// data that must not be purged by the system the way caches are.
    public static func defaultDataRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Multiemu", isDirectory: true)
    }

    static func collect(dataRoot: URL = defaultDataRoot()) -> StorageInfo {
        // Probe the nearest existing ancestor so that a not-yet-created data
        // root still yields correct volume figures on first launch.
        var probePath = dataRoot
        while !FileManager.default.fileExists(atPath: probePath.path), probePath.pathComponents.count > 1 {
            probePath = probePath.deletingLastPathComponent()
        }

        let filesystemType = Self.filesystemType(atPath: probePath.path) ?? "unknown"

        var total: UInt64?
        var available: UInt64?
        var importantUsage: UInt64?

        if let values = try? probePath.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            total = values.volumeTotalCapacity.map { UInt64(max(0, $0)) }
            available = values.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
            importantUsage = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        }

        return StorageInfo(
            dataRootPath: dataRoot.path,
            filesystemType: filesystemType,
            totalBytes: total,
            availableBytes: available,
            availableForImportantUsageBytes: importantUsage,
            // APFS supports sparse files; HFS+ does not. This gates the
            // "dynamically allocated 32 GB default" product requirement.
            supportsSparseFiles: filesystemType.lowercased() == "apfs"
        )
    }

    private static func filesystemType(atPath path: String) -> String? {
        var buffer = statfs()
        guard statfs(path, &buffer) == 0 else { return nil }
        return withUnsafePointer(to: buffer.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { charPointer in
                String(cString: charPointer)
            }
        }
    }
}

// MARK: - Graphics

enum GraphicsProbe {
    static func collect() -> GraphicsInfo {
        let devices = MTLCopyAllDevices()
        let defaultDevice = MTLCreateSystemDefaultDevice()

        return GraphicsInfo(
            metalAvailable: defaultDevice != nil,
            defaultDevice: defaultDevice.map(describe),
            allDevices: devices.map(describe)
        )
    }

    private static func describe(_ device: MTLDevice) -> GPUInfo {
        GPUInfo(
            name: device.name,
            hasUnifiedMemory: device.hasUnifiedMemory,
            isLowPower: device.isLowPower,
            isRemovable: device.isRemovable,
            recommendedMaxWorkingSetBytes: device.recommendedMaxWorkingSetSize,
            maxBufferLengthBytes: UInt64(device.maxBufferLength),
            supportsAppleFamily7OrLater: device.supportsFamily(.apple7),
            supportsMac2: device.supportsFamily(.mac2)
        )
    }
}

// MARK: - Code signing

enum CodeSigningProbe {
    /// `CS_RUNTIME` from `<kern/cs_blobs.h>`. Set when the hardened runtime is
    /// enabled. Read numerically so we do not depend on the Security framework
    /// re-exporting the constant to Swift.
    private static let csRuntimeFlag: UInt32 = 0x0001_0000

    static func collect() -> CodeSigningInfo {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return CodeSigningInfo(
                isSigned: false,
                signingIdentifier: nil,
                teamIdentifier: nil,
                hardenedRuntimeEnabled: false,
                entitlementKeys: []
            )
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return CodeSigningInfo(
                isSigned: false,
                signingIdentifier: nil,
                teamIdentifier: nil,
                hardenedRuntimeEnabled: false,
                entitlementKeys: []
            )
        }

        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        var informationCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, flags, &informationCF) == errSecSuccess,
              let information = informationCF as? [String: Any] else {
            return CodeSigningInfo(
                isSigned: false,
                signingIdentifier: nil,
                teamIdentifier: nil,
                hardenedRuntimeEnabled: false,
                entitlementKeys: []
            )
        }

        let identifier = information[kSecCodeInfoIdentifier as String] as? String
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String
        let signingFlags = (information[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any]

        return CodeSigningInfo(
            isSigned: identifier != nil,
            signingIdentifier: identifier,
            teamIdentifier: team,
            hardenedRuntimeEnabled: (signingFlags & csRuntimeFlag) != 0,
            entitlementKeys: (entitlements?.keys).map { Array($0).sorted() } ?? []
        )
    }
}
