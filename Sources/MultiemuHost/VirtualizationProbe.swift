import Foundation
import Virtualization

/// Detects hardware-virtualization capability.
///
/// Three independent signals are collected rather than one, because they answer
/// different questions and can legitimately disagree:
///
/// * `kern.hv_support` — does the *hardware and kernel* expose the Hypervisor
///   APIs. This is the gate for QEMU's `hvf` accelerator, for
///   Hypervisor.framework, and transitively for Virtualization.framework.
/// * `VZVirtualMachine.isSupported` — can *Virtualization.framework*
///   specifically be used here.
/// * `kern.hv_vmm_present` — is this macOS itself a guest, in which case
///   nested acceleration is generally unavailable.
///
/// None of these check entitlements. A process without
/// `com.apple.security.hypervisor` will still see `kern.hv_support == 1` and
/// then fail at `hv_vm_create`. Entitlement state is reported separately by
/// `CodeSigningProbe` so a launch failure can be attributed correctly.
enum VirtualizationProbe {

    static func collect() -> VirtualizationInfo {
        VirtualizationInfo(
            hypervisorSupported: Sysctl.flag("kern.hv_support"),
            runningInsideVirtualMachine: Sysctl.flag("kern.hv_vmm_present"),
            virtualizationFrameworkSupported: VZVirtualMachine.isSupported,
            hypervisorFrameworkPresent: FileManager.default.fileExists(
                atPath: "/System/Library/Frameworks/Hypervisor.framework"
            ),
            nestedVirtualizationSupported: nestedVirtualizationSupported(),
            rosettaLinuxTranslation: rosettaAvailabilityDescription()
        )
    }

    private static func nestedVirtualizationSupported() -> Bool? {
        if #available(macOS 15.0, *) {
            return VZGenericPlatformConfiguration.isNestedVirtualizationSupported
        }
        return nil
    }

    /// Reported as an opaque string on purpose.
    ///
    /// Rosetta's Linux directory share translates x86_64 **Linux** userspace
    /// binaries inside an arm64 Linux VM via `binfmt_misc`. Android userspace is
    /// bionic/ART on a Linux kernel, not a glibc Linux distribution, and Android
    /// applications are dispatched by the Android runtime rather than by
    /// `binfmt_misc`. This value is collected for host inventory completeness
    /// only; see docs/BACKEND-EVALUATION.md §"Why Rosetta is not an x86 Android
    /// strategy".
    private static func rosettaAvailabilityDescription() -> String? {
        guard #available(macOS 13.0, *) else { return nil }
        let availability = VZLinuxRosettaDirectoryShare.availability

        // The raw value is reported alongside a name so a future SDK adding a
        // case cannot silently turn into a wrong label. The name mapping was
        // established empirically on macOS 26.5.2: a host with Rosetta
        // installed (/Library/Apple/usr/share/rosetta present) reports
        // rawValue 2. See docs/VERIFY.md, item ROSETTA-AVAILABILITY-CASES.
        let name: String
        switch availability {
        case .notSupported: name = "notSupported"
        case .notInstalled: name = "notInstalled"
        case .installed: name = "installed"
        @unknown default: name = "unknown"
        }
        return "\(name) (rawValue \(availability.rawValue))"
    }
}
