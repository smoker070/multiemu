import Darwin
import Foundation
import Hypervisor
import MultiemuHost
import MultiemuSupport

// multiemu-hvprobe — Milestone 2 experiment.
//
// Closes VERIFY.md item HVF-ENTITLEMENT-SET without QEMU, without a guest image
// and without a network connection, by doing the smallest possible real thing:
// create a VM, map a page of host memory into guest physical address space,
// create a vCPU, execute two guest instructions, and read back a guest register.
//
// If this succeeds, then on this Mac:
//   * com.apple.security.hypervisor on an ad-hoc signature is sufficient,
//   * Hypervisor.framework is reachable from a SwiftPM-built binary,
//   * guest code genuinely executes on the CPU (not translated),
//   * the native-VMM backend option is technically real, not theoretical.
//
// If it fails with HV_DENIED, the entitlement or signature is the cause and the
// probe says so explicitly rather than reporting "virtualization unavailable".

let exitOK: Int32 = 0
let exitDenied: Int32 = 3
let exitFailed: Int32 = 4
let exitUnsupportedArchitecture: Int32 = 5

// The HV_* result constants import into Swift as `Int`, while the functions
// return `hv_return_t` (Int32). Narrow once, here, rather than at every call.
let hvSuccess = hv_return_t(truncatingIfNeeded: HV_SUCCESS)
let hvDenied = hv_return_t(truncatingIfNeeded: HV_DENIED)

/// Human-readable name for an `hv_return_t`, for the report.
func describe(_ status: hv_return_t) -> String {
    switch Int(status) {
    case HV_SUCCESS: return "HV_SUCCESS"
    case HV_ERROR: return "HV_ERROR"
    case HV_BUSY: return "HV_BUSY"
    case HV_BAD_ARGUMENT: return "HV_BAD_ARGUMENT"
    case HV_NO_RESOURCES: return "HV_NO_RESOURCES"
    case HV_NO_DEVICE: return "HV_NO_DEVICE"
    case HV_DENIED: return "HV_DENIED"
    case HV_UNSUPPORTED: return "HV_UNSUPPORTED"
    default: return "unknown(0x\(String(format: "%08x", UInt32(bitPattern: status))))"
    }
}

func line(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 32, withPad: " ", startingAt: 0)) \(value)")
}

print("multiemu-hvprobe — Hypervisor.framework entitlement and execution check")
print()

// --- Signature and entitlement state, before we try anything ---
let signing = HostCapabilityProbe(options: .init(runExternalToolVersionCommands: false))
    .collect()
    .codeSigning

print("Code signature")
line("signed", signing.isSigned ? "yes" : "no")
line("identifier", signing.signingIdentifier ?? "none")
line("hardened runtime", signing.hardenedRuntimeEnabled ? "enabled" : "disabled")
line("com.apple.security.hypervisor", signing.hasHypervisorEntitlement ? "PRESENT" : "absent")
line("all entitlements", signing.entitlementKeys.isEmpty ? "none" : signing.entitlementKeys.joined(separator: ", "))
print()

#if arch(arm64)

print("Experiment: execute guest code under Hypervisor.framework (arm64)")

// Page size must match what the hypervisor expects for host allocations.
let pageSize = Int(Sysctl.unsigned("hw.pagesize") ?? 16384)
let guestPhysicalBase: UInt64 = 0

// A two-instruction arm64 program:
//   d2800540  movz x0, #42     ; put a value we can recognise into x0
//   d4000002  hvc  #0          ; trap to the hypervisor, giving us a clean exit
let program: [UInt32] = [0xD280_0540, 0xD400_0002]

// --- 1. Create the VM ---
var status = hv_vm_create(nil)
line("hv_vm_create", describe(status))

if status == hvDenied {
    print()
    print("HV_DENIED. The binary is not authorised to use Hypervisor.framework.")
    print("Sign it with the hypervisor entitlement and try again:")
    print()
    print("  codesign --force --sign - \\")
    print("      --entitlements Resources/entitlements/MultiemuQEMUHelper.entitlements \\")
    print("      .build/debug/multiemu-hvprobe")
    exit(exitDenied)
}
guard status == hvSuccess else { exit(exitFailed) }
defer { hv_vm_destroy() }

// --- 2. Allocate page-aligned host memory and map it as guest RAM ---
var hostMemory: UnsafeMutableRawPointer?
guard posix_memalign(&hostMemory, pageSize, pageSize) == 0, let hostMemory else {
    print("  posix_memalign failed")
    exit(exitFailed)
}
defer { free(hostMemory) }

hostMemory.initializeMemory(as: UInt8.self, repeating: 0, count: pageSize)
program.withUnsafeBytes { bytes in
    hostMemory.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
}

let memoryFlags = hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)
status = hv_vm_map(hostMemory, guestPhysicalBase, pageSize, memoryFlags)
line("hv_vm_map", "\(describe(status))  (\(pageSize) bytes at guest 0x0)")
guard status == hvSuccess else { exit(exitFailed) }
defer { hv_vm_unmap(guestPhysicalBase, pageSize) }

// --- 3. Create a vCPU. It must be used only from the creating thread. ---
var vcpu: hv_vcpu_t = 0
var vcpuExit: UnsafeMutablePointer<hv_vcpu_exit_t>?
status = hv_vcpu_create(&vcpu, &vcpuExit, nil)
line("hv_vcpu_create", describe(status))
guard status == hvSuccess, let vcpuExit else { exit(exitFailed) }
defer { hv_vcpu_destroy(vcpu) }

// EL1h with DAIF masked: the state a bare-metal kernel entry point expects.
status = hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3C4)
guard status == hvSuccess else {
    line("hv_vcpu_set_reg(CPSR)", describe(status))
    exit(exitFailed)
}

status = hv_vcpu_set_reg(vcpu, HV_REG_PC, guestPhysicalBase)
guard status == hvSuccess else {
    line("hv_vcpu_set_reg(PC)", describe(status))
    exit(exitFailed)
}

// --- 4. Run guest code ---
let clock = ContinuousClock()
let started = clock.now
status = hv_vcpu_run(vcpu)
let elapsed = clock.now - started
line("hv_vcpu_run", describe(status))
guard status == hvSuccess else { exit(exitFailed) }

let reason = vcpuExit.pointee.reason
let syndrome = vcpuExit.pointee.exception.syndrome
let exceptionClass = UInt32((syndrome >> 26) & 0x3F)

line("exit reason", reason == HV_EXIT_REASON_EXCEPTION
    ? "HV_EXIT_REASON_EXCEPTION"
    : "raw(\(reason.rawValue))")
line("ESR exception class", "0x\(String(exceptionClass, radix: 16)) " + (exceptionClass == 0x16 ? "(HVC64 — expected)" : "(unexpected)"))

var x0: UInt64 = 0
status = hv_vcpu_get_reg(vcpu, HV_REG_X0, &x0)
guard status == hvSuccess else { exit(exitFailed) }
line("guest x0", "\(x0)")
line("hv_vcpu_run wall time", String(format: "%.3f ms", elapsed.milliseconds))

print()
let executedCorrectly = (reason == HV_EXIT_REASON_EXCEPTION) && (exceptionClass == 0x16) && (x0 == 42)
if executedCorrectly {
    print("RESULT: PASS — guest code executed natively and returned the expected value.")
    print("        Hardware virtualization is usable from a Multiemu-signed binary on this Mac.")
    exit(exitOK)
} else {
    print("RESULT: FAIL — the VM ran but did not produce the expected state.")
    print("        Expected exit HV_EXIT_REASON_EXCEPTION, EC 0x16, x0 = 42.")
    exit(exitFailed)
}

#elseif arch(x86_64)

print("Experiment: create a VM under Hypervisor.framework (x86_64)")

// The x86_64 entry point differs from arm64 (options word rather than a config
// object), and executing guest code requires VMCS setup that is out of scope
// for an entitlement check. Creating and destroying the VM is sufficient to
// prove the entitlement and framework access, which is what this probe is for.
let status = hv_vm_create(hv_vm_options_t(HV_VM_DEFAULT))
line("hv_vm_create", describe(status))

if status == hvDenied {
    print()
    print("HV_DENIED — sign the binary with com.apple.security.hypervisor.")
    exit(exitDenied)
}
guard status == hvSuccess else { exit(exitFailed) }
hv_vm_destroy()

print()
print("RESULT: PASS — Hypervisor.framework is usable from a Multiemu-signed binary.")
print("        Guest execution is not exercised on x86_64 by this probe.")
exit(exitOK)

#else

print("Unsupported host architecture for this probe.")
exit(exitUnsupportedArchitecture)

#endif
