import Foundation
import MultiemuHost
import MultiemuSupport

/// A virtual device's resource request, validated before any guest is launched.
public struct GuestResourceRequest: Sendable, Equatable {
    public var memoryBytes: UInt64
    public var storageBytes: UInt64
    public var vcpuCount: Int

    public init(memoryBytes: UInt64, storageBytes: UInt64, vcpuCount: Int) {
        self.memoryBytes = memoryBytes
        self.storageBytes = storageBytes
        self.vcpuCount = vcpuCount
    }

    /// Product default: 4 GiB RAM, 32 GiB dynamically allocated storage.
    public static func defaultProfile(vcpuCount: Int) -> GuestResourceRequest {
        GuestResourceRequest(
            memoryBytes: 4 * ByteCount.giB,
            storageBytes: 32 * ByteCount.giB,
            vcpuCount: vcpuCount
        )
    }
}

/// What devices that are *already running* have claimed.
///
/// Validation without this admits every device against the bare host, so on a
/// 16 GiB Mac two devices at the per-device ceiling both pass and both start.
/// Multi-instance makes the missing term visible; a single-device product never
/// would have.
public struct CommittedResources: Sendable, Equatable {
    public var deviceCount: Int
    public var memoryBytes: UInt64
    public var vcpuCount: Int
    /// Loopback ports running devices have forwarded. A second device binding
    /// one of these fails inside QEMU, which surfaces as a broken emulator
    /// rather than as the port clash it is.
    public var hostPorts: Set<Int>

    public init(
        deviceCount: Int = 0,
        memoryBytes: UInt64 = 0,
        vcpuCount: Int = 0,
        hostPorts: Set<Int> = []
    ) {
        self.deviceCount = deviceCount
        self.memoryBytes = memoryBytes
        self.vcpuCount = vcpuCount
        self.hostPorts = hostPorts
    }

    /// Nothing is running. The default, so every existing call site keeps its
    /// current single-device meaning.
    public static let none = CommittedResources()

    /// Totals the requests of the devices currently running.
    ///
    /// Storage is deliberately absent. A device's disk is created when the
    /// device is created, not when it starts, so whatever it occupies is
    /// already missing from free space by the time this is consulted — and
    /// `qemu-img` does not preallocate a qcow2 on any filesystem, so a
    /// 64 GiB device occupies about 200 KiB until a guest writes to it.
    /// Counting configured sizes here would refuse admissions on space that
    /// was never taken.
    public static func summing(
        _ requests: [GuestResourceRequest],
        hostPorts: Set<Int> = []
    ) -> CommittedResources {
        CommittedResources(
            deviceCount: requests.count,
            memoryBytes: requests.reduce(0) { $0 + $1.memoryBytes },
            vcpuCount: requests.reduce(0) { $0 + $1.vcpuCount },
            hostPorts: hostPorts
        )
    }
}

public struct ResourceValidationResult: Sendable {
    public var errors: [MultiemuError]
    public var warnings: [String]

    public var isAllowed: Bool { errors.isEmpty }

    public init(errors: [MultiemuError], warnings: [String]) {
        self.errors = errors
        self.warnings = warnings
    }
}

/// Validates a resource request against real host figures.
///
/// The product constraint is explicit: memory allocation must be validated
/// against available host memory before launching a guest, and virtual disks
/// must not be eagerly allocated when a sparse format is available. Both rules
/// live here so no launch path can skip them.
public enum ResourceValidator {

    /// RAM kept away from guests so macOS, the window server and Multiemu itself
    /// keep running. A guest that pushes the host into heavy swap produces
    /// exactly the "stable FPS number, terrible frame pacing" outcome the
    /// product targets reject, so this is a hard reservation, not a hint.
    public static let hostReserveBytes: UInt64 = 4 * ByteCount.giB

    /// Upper bound on the fraction of installed RAM guests may claim.
    ///
    /// Applied twice, deliberately: to a single guest, and to the total across
    /// every running guest. One number for both is a choice, not an oversight —
    /// the reservation exists to keep macOS responsive, and the host does not
    /// care whether the RAM went to one guest or four. It is conservative on a
    /// large Mac, which is the safe direction to be wrong in.
    public static let maximumPhysicalMemoryFraction = 0.60

    /// Smallest guest memory profile the product supports.
    public static let minimumGuestMemoryBytes: UInt64 = 2 * ByteCount.giB

    /// Free space that must remain after accounting for a new virtual device.
    public static let storageHeadroomBytes: UInt64 = 8 * ByteCount.giB

    public static func maximumAllowedGuestMemory(physicalBytes: UInt64) -> UInt64 {
        let fractionLimit = UInt64(Double(physicalBytes) * maximumPhysicalMemoryFraction)
        let reserveLimit = physicalBytes > hostReserveBytes ? physicalBytes - hostReserveBytes : 0
        return min(fractionLimit, reserveLimit)
    }

    public static func validate(
        _ request: GuestResourceRequest,
        host: HostCapabilities,
        committed: CommittedResources = .none
    ) -> ResourceValidationResult {
        var errors: [MultiemuError] = []
        var warnings: [String] = []

        // --- Memory ---
        let physical = host.memory.physicalBytes
        let maximumAllowed = maximumAllowedGuestMemory(physicalBytes: physical)

        if request.memoryBytes < minimumGuestMemoryBytes {
            errors.append(.invalidConfiguration(
                field: "Guest memory",
                detail: "\(ByteCount.describe(request.memoryBytes)) is below the \(ByteCount.describe(minimumGuestMemoryBytes)) minimum supported profile."
            ))
        }

        if request.memoryBytes > maximumAllowed {
            errors.append(.insufficientMemory(
                requestedBytes: request.memoryBytes,
                hostPhysicalBytes: physical,
                hostAvailableBytes: host.memory.estimatedAvailableBytes
            ))
        } else if committed.memoryBytes + request.memoryBytes > maximumAllowed {
            errors.append(.hostBudgetExhausted(
                resource: "guest memory",
                requestedBytes: request.memoryBytes,
                committedBytes: committed.memoryBytes,
                budgetBytes: maximumAllowed,
                runningDeviceCount: committed.deviceCount
            ))
        } else if committed.memoryBytes + request.memoryBytes > host.memory.estimatedAvailableBytes {
            // Compared as a total. Against the request alone this warning went
            // silent for every device after the first, which is exactly when
            // swapping becomes likely.
            warnings.append("""
                \(ByteCount.describe(request.memoryBytes)) requested, \
                \(ByteCount.describe(committed.memoryBytes + request.memoryBytes)) in total, but only about \
                \(ByteCount.describe(host.memory.estimatedAvailableBytes)) is currently available. The guest will \
                still start, but macOS will compress or swap to satisfy it and frame pacing may suffer.
                """)
        }

        // --- Storage ---
        let available = host.storage.availableForImportantUsageBytes
            ?? host.storage.availableBytes
            ?? 0

        if !host.storage.supportsSparseFiles {
            warnings.append("""
                \(host.storage.dataRootPath) is on a \(host.storage.filesystemType) volume, which does not support \
                sparse files. The full \(ByteCount.describe(request.storageBytes)) will be allocated up front.
                """)
            if request.storageBytes + storageHeadroomBytes > available {
                errors.append(.insufficientStorage(
                    requestedBytes: request.storageBytes,
                    availableBytes: available,
                    path: host.storage.dataRootPath
                ))
            }
        } else {
            // Sparse: the file's logical size may exceed free space, but a device
            // that can never grow to a usable size is still a configuration error.
            if committed.deviceCount > 0, available < storageHeadroomBytes * UInt64(committed.deviceCount + 1) {
                warnings.append("""
                    \(committed.deviceCount + 1) devices will be growing their disks into the same \
                    \(ByteCount.describe(available)) of free space. Each starts at a few hundred kilobytes, \
                    so this is allowed, but they share one pool and it drains faster with every device.
                    """)
            }
            if available < storageHeadroomBytes {
                errors.append(.insufficientStorage(
                    requestedBytes: request.storageBytes,
                    availableBytes: available,
                    path: host.storage.dataRootPath
                ))
            } else if available < request.storageBytes {
                warnings.append("""
                    The device is configured for \(ByteCount.describe(request.storageBytes)) but only \
                    \(ByteCount.describe(available)) is free. The disk image grows on demand, so this is allowed, \
                    but the guest will report more free space than the Mac can actually provide.
                    """)
            }
        }

        // --- vCPUs ---
        if request.vcpuCount < 1 {
            errors.append(.invalidConfiguration(field: "vCPU count", detail: "At least one virtual CPU is required."))
        } else if request.vcpuCount > host.cpu.logicalCores {
            errors.append(.invalidConfiguration(
                field: "vCPU count",
                detail: "\(request.vcpuCount) virtual CPUs requested but this Mac has \(host.cpu.logicalCores) logical cores."
            ))
        } else if committed.vcpuCount + request.vcpuCount > host.cpu.logicalCores {
            warnings.append("""
                \(request.vcpuCount) virtual CPUs requested with \(committed.vcpuCount) already running \
                on \(host.cpu.logicalCores) logical cores. Guests time-share cores rather than failing, and \
                measured contention is mild, but frame pacing degrades as oversubscription grows.
                """)
        } else if request.vcpuCount > host.cpu.recommendedGuestVCPUCount {
            warnings.append("""
                \(request.vcpuCount) virtual CPUs exceeds the recommended \(host.cpu.recommendedGuestVCPUCount) for this \
                Mac. Guest threads will be scheduled onto efficiency cores, which typically hurts frame pacing more \
                than the extra cores help throughput.
                """)
        }

        return ResourceValidationResult(errors: errors, warnings: warnings)
    }
}
