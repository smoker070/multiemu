import Foundation
import MultiemuSupport

extension HostCapabilities {

    /// Builds a fully specified `HostCapabilities` without touching the machine.
    ///
    /// Shipped in the library rather than a test target because two consumers
    /// need it: unit tests that must produce identical results on any Mac, and
    /// SwiftUI previews in the application shell (Milestone 17), which cannot
    /// call a real probe.
    public static func makeFixture(
        macOSMajor: Int = 14,
        architecture: HostArchitecture = .appleSilicon,
        physicalMemoryBytes: UInt64 = 16 * ByteCount.giB,
        estimatedAvailableMemoryBytes: UInt64 = 8 * ByteCount.giB,
        logicalCores: Int = 10,
        physicalCores: Int = 10,
        performanceCores: Int? = 4,
        efficiencyCores: Int? = 6,
        filesystemType: String = "apfs",
        availableStorageBytes: UInt64 = 200 * ByteCount.giB,
        metalAvailable: Bool = true,
        hypervisorSupported: Bool? = true,
        runningInsideVirtualMachine: Bool? = false,
        virtualizationFrameworkSupported: Bool = true,
        entitlementKeys: [String] = [],
        externalTools: [ExternalTool] = []
    ) -> HostCapabilities {
        HostCapabilities(
            collectedAt: Date(timeIntervalSince1970: 0),
            operatingSystem: OperatingSystemInfo(
                productVersion: "\(macOSMajor).0.0",
                buildVersion: "FIXTURE",
                majorVersion: macOSMajor,
                minorVersion: 0,
                patchVersion: 0
            ),
            cpu: CPUInfo(
                architecture: architecture,
                brand: "Fixture CPU",
                machineModel: "Fixture,1",
                logicalCores: logicalCores,
                physicalCores: physicalCores,
                performanceCores: performanceCores,
                efficiencyCores: efficiencyCores,
                cacheLineSizeBytes: 128,
                cpuFamily: 0
            ),
            memory: MemoryInfo(
                physicalBytes: physicalMemoryBytes,
                pageSizeBytes: 16_384,
                estimatedAvailableBytes: estimatedAvailableMemoryBytes,
                freeBytes: estimatedAvailableMemoryBytes,
                inactiveBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                swapTotalBytes: nil,
                swapUsedBytes: nil
            ),
            storage: StorageInfo(
                dataRootPath: "/fixture/Application Support/Multiemu",
                filesystemType: filesystemType,
                totalBytes: availableStorageBytes * 2,
                availableBytes: availableStorageBytes,
                availableForImportantUsageBytes: availableStorageBytes,
                supportsSparseFiles: filesystemType.lowercased() == "apfs"
            ),
            graphics: GraphicsInfo(
                metalAvailable: metalAvailable,
                defaultDevice: metalAvailable
                    ? GPUInfo(
                        name: "Fixture GPU",
                        hasUnifiedMemory: architecture == .appleSilicon,
                        isLowPower: false,
                        isRemovable: false,
                        recommendedMaxWorkingSetBytes: 8 * ByteCount.giB,
                        maxBufferLengthBytes: 4 * ByteCount.giB,
                        supportsAppleFamily7OrLater: architecture == .appleSilicon,
                        supportsMac2: architecture == .intel
                    )
                    : nil,
                allDevices: []
            ),
            virtualization: VirtualizationInfo(
                hypervisorSupported: hypervisorSupported,
                runningInsideVirtualMachine: runningInsideVirtualMachine,
                virtualizationFrameworkSupported: virtualizationFrameworkSupported,
                hypervisorFrameworkPresent: true,
                nestedVirtualizationSupported: nil,
                rosettaLinuxTranslation: nil
            ),
            codeSigning: CodeSigningInfo(
                isSigned: !entitlementKeys.isEmpty,
                signingIdentifier: "fixture",
                teamIdentifier: nil,
                hardenedRuntimeEnabled: false,
                entitlementKeys: entitlementKeys
            ),
            externalTools: externalTools,
            unverifiedClaims: []
        )
    }
}
