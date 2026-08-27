import Foundation

/// The host architecture Multiemu is running on.
///
/// This is the *host* CPU. Guest CPU architecture is a separate concept and
/// lives in `MultiemuBackend.GuestArchitecture`; conflating the two is how
/// emulator projects end up with `#if arch(arm64)` scattered through their UI.
public enum HostArchitecture: String, Codable, Sendable, CaseIterable {
    case appleSilicon = "arm64"
    case intel = "x86_64"
    case unknown

    public var displayName: String {
        switch self {
        case .appleSilicon: return "Apple Silicon (arm64)"
        case .intel: return "Intel (x86_64)"
        case .unknown: return "Unknown"
        }
    }
}

public struct OperatingSystemInfo: Codable, Sendable, Equatable {
    public var productVersion: String
    public var buildVersion: String
    public var majorVersion: Int
    public var minorVersion: Int
    public var patchVersion: Int

    public init(
        productVersion: String,
        buildVersion: String,
        majorVersion: Int,
        minorVersion: Int,
        patchVersion: Int
    ) {
        self.productVersion = productVersion
        self.buildVersion = buildVersion
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.patchVersion = patchVersion
    }

    /// Product requirement: macOS 14.0 or later.
    public var meetsMinimumRequirement: Bool { majorVersion >= 14 }
}

public struct CPUInfo: Codable, Sendable, Equatable {
    public var architecture: HostArchitecture
    public var brand: String
    public var machineModel: String
    public var logicalCores: Int
    public var physicalCores: Int
    /// Apple Silicon only. `hw.perflevel0.*` is the performance cluster.
    public var performanceCores: Int?
    /// Apple Silicon only. `hw.perflevel1.*` is the efficiency cluster.
    public var efficiencyCores: Int?
    public var cacheLineSizeBytes: Int?
    public var cpuFamily: Int64?

    public init(
        architecture: HostArchitecture,
        brand: String,
        machineModel: String,
        logicalCores: Int,
        physicalCores: Int,
        performanceCores: Int?,
        efficiencyCores: Int?,
        cacheLineSizeBytes: Int?,
        cpuFamily: Int64?
    ) {
        self.architecture = architecture
        self.brand = brand
        self.machineModel = machineModel
        self.logicalCores = logicalCores
        self.physicalCores = physicalCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.cacheLineSizeBytes = cacheLineSizeBytes
        self.cpuFamily = cpuFamily
    }

    /// vCPU count we would give a guest by default.
    ///
    /// On Apple Silicon we intentionally cap at the performance-core count:
    /// scheduling guest vCPUs onto efficiency cores produces the "high FPS
    /// number, terrible frame pacing" failure the product spec explicitly
    /// rejects. This is a starting policy to be validated in Milestone 19, not
    /// a measured optimum.
    public var recommendedGuestVCPUCount: Int {
        if let performanceCores, performanceCores > 0 {
            return max(2, min(performanceCores, 8))
        }
        return max(2, min(physicalCores / 2, 8))
    }
}

public struct MemoryInfo: Codable, Sendable, Equatable {
    public var physicalBytes: UInt64
    public var pageSizeBytes: UInt64
    /// Estimate of memory that could be handed to a guest without immediately
    /// forcing compression or swap. Derived, not reported by the kernel.
    public var estimatedAvailableBytes: UInt64
    public var freeBytes: UInt64
    public var inactiveBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var swapTotalBytes: UInt64?
    public var swapUsedBytes: UInt64?

    public init(
        physicalBytes: UInt64,
        pageSizeBytes: UInt64,
        estimatedAvailableBytes: UInt64,
        freeBytes: UInt64,
        inactiveBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        swapTotalBytes: UInt64?,
        swapUsedBytes: UInt64?
    ) {
        self.physicalBytes = physicalBytes
        self.pageSizeBytes = pageSizeBytes
        self.estimatedAvailableBytes = estimatedAvailableBytes
        self.freeBytes = freeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
    }
}

public struct StorageInfo: Codable, Sendable, Equatable {
    public var dataRootPath: String
    public var filesystemType: String
    public var totalBytes: UInt64?
    public var availableBytes: UInt64?
    /// `URLResourceKey.volumeAvailableCapacityForImportantUsage` — the number
    /// macOS itself uses when deciding whether a large write will succeed.
    public var availableForImportantUsageBytes: UInt64?
    /// Whether the volume supports sparse files. Required by the product
    /// constraint "avoid allocating the full configured virtual disk eagerly".
    public var supportsSparseFiles: Bool

    public init(
        dataRootPath: String,
        filesystemType: String,
        totalBytes: UInt64?,
        availableBytes: UInt64?,
        availableForImportantUsageBytes: UInt64?,
        supportsSparseFiles: Bool
    ) {
        self.dataRootPath = dataRootPath
        self.filesystemType = filesystemType
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
        self.supportsSparseFiles = supportsSparseFiles
    }
}

public struct GPUInfo: Codable, Sendable, Equatable {
    public var name: String
    public var hasUnifiedMemory: Bool
    public var isLowPower: Bool
    public var isRemovable: Bool
    public var recommendedMaxWorkingSetBytes: UInt64
    public var maxBufferLengthBytes: UInt64
    public var supportsAppleFamily7OrLater: Bool
    public var supportsMac2: Bool

    public init(
        name: String,
        hasUnifiedMemory: Bool,
        isLowPower: Bool,
        isRemovable: Bool,
        recommendedMaxWorkingSetBytes: UInt64,
        maxBufferLengthBytes: UInt64,
        supportsAppleFamily7OrLater: Bool,
        supportsMac2: Bool
    ) {
        self.name = name
        self.hasUnifiedMemory = hasUnifiedMemory
        self.isLowPower = isLowPower
        self.isRemovable = isRemovable
        self.recommendedMaxWorkingSetBytes = recommendedMaxWorkingSetBytes
        self.maxBufferLengthBytes = maxBufferLengthBytes
        self.supportsAppleFamily7OrLater = supportsAppleFamily7OrLater
        self.supportsMac2 = supportsMac2
    }
}

public struct GraphicsInfo: Codable, Sendable, Equatable {
    public var metalAvailable: Bool
    public var defaultDevice: GPUInfo?
    public var allDevices: [GPUInfo]

    public init(metalAvailable: Bool, defaultDevice: GPUInfo?, allDevices: [GPUInfo]) {
        self.metalAvailable = metalAvailable
        self.defaultDevice = defaultDevice
        self.allDevices = allDevices
    }
}

public struct VirtualizationInfo: Codable, Sendable, Equatable {
    /// `kern.hv_support`: whether this Mac supports the Hypervisor APIs at all.
    /// This is Apple's documented capability check and it gates every
    /// hardware-accelerated backend (Hypervisor.framework, Virtualization.framework,
    /// and QEMU's `hvf` accelerator, which is built on Hypervisor.framework).
    public var hypervisorSupported: Bool?
    /// `kern.hv_vmm_present`: whether *this* macOS is itself running inside a VM.
    /// Relevant because nested acceleration is not generally available.
    public var runningInsideVirtualMachine: Bool?
    /// `VZVirtualMachine.isSupported`.
    public var virtualizationFrameworkSupported: Bool
    public var hypervisorFrameworkPresent: Bool
    /// macOS 15+ only; `nil` on earlier systems or when the API is unavailable.
    public var nestedVirtualizationSupported: Bool?
    /// Raw description of `VZLinuxRosettaDirectoryShare.availability`.
    /// Recorded for completeness only — see docs/BACKEND-EVALUATION.md for why
    /// Rosetta's Linux translation is not an Android x86 strategy.
    public var rosettaLinuxTranslation: String?

    public init(
        hypervisorSupported: Bool?,
        runningInsideVirtualMachine: Bool?,
        virtualizationFrameworkSupported: Bool,
        hypervisorFrameworkPresent: Bool,
        nestedVirtualizationSupported: Bool?,
        rosettaLinuxTranslation: String?
    ) {
        self.hypervisorSupported = hypervisorSupported
        self.runningInsideVirtualMachine = runningInsideVirtualMachine
        self.virtualizationFrameworkSupported = virtualizationFrameworkSupported
        self.hypervisorFrameworkPresent = hypervisorFrameworkPresent
        self.nestedVirtualizationSupported = nestedVirtualizationSupported
        self.rosettaLinuxTranslation = rosettaLinuxTranslation
    }
}

public struct CodeSigningInfo: Codable, Sendable, Equatable {
    public var isSigned: Bool
    public var signingIdentifier: String?
    public var teamIdentifier: String?
    public var hardenedRuntimeEnabled: Bool
    public var entitlementKeys: [String]

    public var hasVirtualizationEntitlement: Bool {
        entitlementKeys.contains("com.apple.security.virtualization")
    }

    public var hasHypervisorEntitlement: Bool {
        entitlementKeys.contains("com.apple.security.hypervisor")
    }

    public init(
        isSigned: Bool,
        signingIdentifier: String?,
        teamIdentifier: String?,
        hardenedRuntimeEnabled: Bool,
        entitlementKeys: [String]
    ) {
        self.isSigned = isSigned
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.hardenedRuntimeEnabled = hardenedRuntimeEnabled
        self.entitlementKeys = entitlementKeys
    }
}

public struct ExternalTool: Codable, Sendable, Equatable {
    public var name: String
    public var purpose: String
    public var requiredFromMilestone: String
    public var resolvedPath: String?
    public var version: String?
    public var installHint: String

    public var isPresent: Bool { resolvedPath != nil }

    public init(
        name: String,
        purpose: String,
        requiredFromMilestone: String,
        resolvedPath: String?,
        version: String?,
        installHint: String
    ) {
        self.name = name
        self.purpose = purpose
        self.requiredFromMilestone = requiredFromMilestone
        self.resolvedPath = resolvedPath
        self.version = version
        self.installHint = installHint
    }
}

/// A claim this code makes that has not yet been confirmed against primary
/// documentation or a live test on the current OS version.
///
/// The project rule is that version-sensitive framework behaviour must be
/// verified, not assumed. Rather than silently guessing, the probe emits the
/// open questions with the exact command that closes them. These are mirrored
/// in `docs/VERIFY.md`.
public struct UnverifiedClaim: Codable, Sendable, Equatable {
    public var id: String
    public var claim: String
    public var verification: String

    public init(id: String, claim: String, verification: String) {
        self.id = id
        self.claim = claim
        self.verification = verification
    }
}

/// Complete host capability snapshot.
///
/// `Codable` because it is (a) the payload of `multiemu-probe --format json`,
/// (b) part of every diagnostics bundle, and (c) the input to regression tests
/// that must run on hosts other than the developer's.
public struct HostCapabilities: Codable, Sendable, Equatable {
    /// Bump when field semantics change so old diagnostics bundles stay readable.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var collectedAt: Date
    public var operatingSystem: OperatingSystemInfo
    public var cpu: CPUInfo
    public var memory: MemoryInfo
    public var storage: StorageInfo
    public var graphics: GraphicsInfo
    public var virtualization: VirtualizationInfo
    public var codeSigning: CodeSigningInfo
    public var externalTools: [ExternalTool]
    public var unverifiedClaims: [UnverifiedClaim]

    public init(
        schemaVersion: Int = HostCapabilities.currentSchemaVersion,
        collectedAt: Date,
        operatingSystem: OperatingSystemInfo,
        cpu: CPUInfo,
        memory: MemoryInfo,
        storage: StorageInfo,
        graphics: GraphicsInfo,
        virtualization: VirtualizationInfo,
        codeSigning: CodeSigningInfo,
        externalTools: [ExternalTool],
        unverifiedClaims: [UnverifiedClaim]
    ) {
        self.schemaVersion = schemaVersion
        self.collectedAt = collectedAt
        self.operatingSystem = operatingSystem
        self.cpu = cpu
        self.memory = memory
        self.storage = storage
        self.graphics = graphics
        self.virtualization = virtualization
        self.codeSigning = codeSigning
        self.externalTools = externalTools
        self.unverifiedClaims = unverifiedClaims
    }

    /// Hardware-assisted virtualization is usable on this host.
    /// Note this reports the *host* capability only; whether a given guest can
    /// use it depends on architecture match (see `MultiemuBackend`).
    public var hardwareVirtualizationAvailable: Bool {
        (virtualization.hypervisorSupported ?? false)
            && (virtualization.runningInsideVirtualMachine != true)
    }
}
