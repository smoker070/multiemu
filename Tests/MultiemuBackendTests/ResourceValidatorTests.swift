import Foundation
import Testing
@testable import MultiemuBackend
import MultiemuHost
import MultiemuSupport

@Suite("Resource preflight")
struct ResourceValidatorTests {

    @Test("Default 4 GiB / 32 GiB profile is allowed on a 16 GiB Mac")
    func defaultProfileOn16GiB() {
        let host = HostCapabilities.makeFixture(
            physicalMemoryBytes: 16 * ByteCount.giB,
            estimatedAvailableMemoryBytes: 8 * ByteCount.giB
        )
        let result = ResourceValidator.validate(.defaultProfile(vcpuCount: 4), host: host)
        #expect(result.isAllowed)
        #expect(result.warnings.isEmpty)
    }

    @Test("Default profile is allowed on an 8 GiB Mac but sits at the limit")
    func defaultProfileOn8GiB() {
        let host = HostCapabilities.makeFixture(
            physicalMemoryBytes: 8 * ByteCount.giB,
            estimatedAvailableMemoryBytes: 3 * ByteCount.giB
        )
        // max = min(60% of 8 GiB = 4.8, 8 - 4 reserve = 4) = 4 GiB exactly.
        #expect(ResourceValidator.maximumAllowedGuestMemory(physicalBytes: 8 * ByteCount.giB) == 4 * ByteCount.giB)

        let result = ResourceValidator.validate(.defaultProfile(vcpuCount: 4), host: host)
        #expect(result.isAllowed)
        // Only 3 GiB is actually free, so the user is warned about swapping.
        #expect(result.warnings.contains { $0.contains("currently available") })
    }

    @Test("An 8 GiB guest is refused on an 8 GiB Mac")
    func oversizedGuestRefused() {
        let host = HostCapabilities.makeFixture(physicalMemoryBytes: 8 * ByteCount.giB)
        let request = GuestResourceRequest(
            memoryBytes: 8 * ByteCount.giB,
            storageBytes: 32 * ByteCount.giB,
            vcpuCount: 4
        )
        let result = ResourceValidator.validate(request, host: host)
        #expect(!result.isAllowed)
        #expect(result.errors.contains { if case .insufficientMemory = $0 { return true } else { return false } })
    }

    @Test("An 8 GiB guest is allowed on a 32 GiB Mac")
    func largeGuestOnLargeHost() {
        let host = HostCapabilities.makeFixture(
            physicalMemoryBytes: 32 * ByteCount.giB,
            estimatedAvailableMemoryBytes: 20 * ByteCount.giB
        )
        let request = GuestResourceRequest(
            memoryBytes: 8 * ByteCount.giB,
            storageBytes: 64 * ByteCount.giB,
            vcpuCount: 6
        )
        #expect(ResourceValidator.validate(request, host: host).isAllowed)
    }

    @Test("Below-minimum guest memory is rejected as a configuration error")
    func belowMinimumMemory() {
        let request = GuestResourceRequest(
            memoryBytes: 1 * ByteCount.giB,
            storageBytes: 32 * ByteCount.giB,
            vcpuCount: 2
        )
        let result = ResourceValidator.validate(request, host: .makeFixture())
        #expect(!result.isAllowed)
        #expect(result.errors.contains { if case .invalidConfiguration = $0 { return true } else { return false } })
    }

    @Test("Sparse volumes allow a disk larger than free space, with a warning")
    func sparseOversubscription() {
        let host = HostCapabilities.makeFixture(
            filesystemType: "apfs",
            availableStorageBytes: 40 * ByteCount.giB
        )
        let request = GuestResourceRequest(
            memoryBytes: 4 * ByteCount.giB,
            storageBytes: 128 * ByteCount.giB,
            vcpuCount: 4
        )
        let result = ResourceValidator.validate(request, host: host)
        #expect(result.isAllowed)
        #expect(result.warnings.contains { $0.contains("grows on demand") })
    }

    @Test("Non-sparse volumes refuse a disk larger than free space")
    func nonSparseRefusal() {
        let host = HostCapabilities.makeFixture(
            filesystemType: "hfs",
            availableStorageBytes: 40 * ByteCount.giB
        )
        let request = GuestResourceRequest(
            memoryBytes: 4 * ByteCount.giB,
            storageBytes: 128 * ByteCount.giB,
            vcpuCount: 4
        )
        let result = ResourceValidator.validate(request, host: host)
        #expect(!result.isAllowed)
        #expect(result.errors.contains { if case .insufficientStorage = $0 { return true } else { return false } })
        #expect(result.warnings.contains { $0.contains("sparse") })
    }

    @Test("A nearly full volume is refused even with sparse support")
    func noHeadroomRefused() {
        let host = HostCapabilities.makeFixture(
            filesystemType: "apfs",
            availableStorageBytes: 2 * ByteCount.giB
        )
        let result = ResourceValidator.validate(.defaultProfile(vcpuCount: 4), host: host)
        #expect(!result.isAllowed)
        #expect(result.errors.contains { if case .insufficientStorage = $0 { return true } else { return false } })
    }

    @Test("Requesting more vCPUs than the Mac has is refused")
    func tooManyVCPUs() {
        let host = HostCapabilities.makeFixture(logicalCores: 8, physicalCores: 8, performanceCores: 4, efficiencyCores: 4)
        let request = GuestResourceRequest(memoryBytes: 4 * ByteCount.giB, storageBytes: 32 * ByteCount.giB, vcpuCount: 12)
        let result = ResourceValidator.validate(request, host: host)
        #expect(!result.isAllowed)
    }

    @Test("Exceeding the recommended vCPU count warns about efficiency-core scheduling")
    func vcpuOverRecommendationWarns() {
        let host = HostCapabilities.makeFixture(logicalCores: 10, physicalCores: 10, performanceCores: 4, efficiencyCores: 6)
        #expect(host.cpu.recommendedGuestVCPUCount == 4)
        let request = GuestResourceRequest(memoryBytes: 4 * ByteCount.giB, storageBytes: 32 * ByteCount.giB, vcpuCount: 9)
        let result = ResourceValidator.validate(request, host: host)
        #expect(result.isAllowed)
        #expect(result.warnings.contains { $0.contains("efficiency cores") })
    }

    @Test("Errors carry actionable remediation text")
    func remediationIsActionable() {
        let host = HostCapabilities.makeFixture(physicalMemoryBytes: 8 * ByteCount.giB)
        let request = GuestResourceRequest(memoryBytes: 8 * ByteCount.giB, storageBytes: 32 * ByteCount.giB, vcpuCount: 4)
        let result = ResourceValidator.validate(request, host: host)
        let text = result.errors.map(\.remediation).joined(separator: " ")
        #expect(text.contains("GiB"))
        #expect(text.lowercased().contains("reduce") || text.lowercased().contains("close"))
    }
}
