import Darwin
import Foundation
import MultiemuHost
import MultiemuSupport
import MultiemuVZ
import Virtualization

// multiemu-vzprobe — Milestone 2 experiment.
//
// Reads Virtualization.framework's actual API surface off the running system and
// runs Apple's own configuration validation, to settle whether VZ could be the
// shipping Android backend. No guest image and no network required.

func heading(_ title: String) {
    print("")
    print(title)
    print(String(repeating: "-", count: title.count))
}

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 46, withPad: " ", startingAt: 0)) \(value)")
}

let signing = HostCapabilityProbe(options: .init(runExternalToolVersionCommands: false))
    .collect()
    .codeSigning

print("multiemu-vzprobe — Virtualization.framework capability surface")
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

heading("Availability")
row("VZVirtualMachine.isSupported", VZVirtualMachine.isSupported ? "true" : "false")
row("virtualization entitlement", signing.hasVirtualizationEntitlement ? "PRESENT" : "absent")
if #available(macOS 15.0, *) {
    row("nested virtualization", VZGenericPlatformConfiguration.isNestedVirtualizationSupported ? "supported" : "not supported")
}
row("min memory", ByteCount.describe(VZVirtualMachineConfiguration.minimumAllowedMemorySize))
row("max memory", ByteCount.describe(VZVirtualMachineConfiguration.maximumAllowedMemorySize))
row("min CPU count", "\(VZVirtualMachineConfiguration.minimumAllowedCPUCount)")
row("max CPU count", "\(VZVirtualMachineConfiguration.maximumAllowedCPUCount)")

heading("Class surface (present / absent on this macOS)")
for surface in VZCapabilityReport.allSurfaces() {
    if surface.exists {
        row(surface.className, surface.properties.isEmpty ? "(no declared properties)" : surface.properties.joined(separator: ", "))
    } else {
        row(surface.className, "ABSENT")
    }
}

heading("Graphics: is any renderer or 3D capability exposed?")
let rendererProperties = VZCapabilityReport.rendererRelatedProperties()
if rendererProperties.isEmpty {
    print("  No property on any graphics configuration class matches any of:")
    print("    \(VZCapabilityReport.rendererIndicators.joined(separator: ", "))")
    print("  => There is no public API to attach a 3D renderer (virgl, Venus, gfxstream)")
    print("     to VZVirtioGraphicsDeviceConfiguration on this macOS version.")
} else {
    for property in rendererProperties { row("candidate", property) }
}

heading("Save / restore API on VZVirtualMachine")
let saveMethods = VZCapabilityReport.methods(of: "VZVirtualMachine", containing: "MachineState")
if saveMethods.isEmpty {
    print("  none found")
} else {
    for method in saveMethods { row("selector", method) }
}

// --- Configuration validation, with a real (empty) kernel file on disk ---
heading("Configuration validation")

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("multiemu-vzprobe-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

let fakeKernel = scratch.appendingPathComponent("vmlinuz")
FileManager.default.createFile(atPath: fakeKernel.path, contents: Data())

let missingKernel = scratch.appendingPathComponent("does-not-exist")

let consolePipe = Pipe()

func validate(kernel: URL, label: String) -> VZVirtualMachineConfiguration? {
    do {
        let configuration = try VZLinuxPrototype.makeConfiguration(
            .init(kernelURL: kernel),
            consoleOutput: consolePipe.fileHandleForWriting,
            consoleInput: consolePipe.fileHandleForReading
        )
        row(label, "validate() succeeded")
        return configuration
    } catch {
        row(label, "validate() threw: \(error.localizedDescription)")
        return nil
    }
}

let configuration = validate(kernel: fakeKernel, label: "empty kernel file")
_ = validate(kernel: missingKernel, label: "missing kernel file")

if let configuration {
    switch VZLinuxPrototype.saveRestoreSupport(for: configuration) {
    case .none:
        row("validateSaveRestoreSupport", "API unavailable on this macOS")
    case .success:
        row("validateSaveRestoreSupport", "SUPPORTED for this device set")
    case .failure(let error):
        row("validateSaveRestoreSupport", "unsupported: \(error.localizedDescription)")
    }
}

print("")
print("Interpretation is recorded in docs/VERIFY.md; this tool only reports facts.")
