import Foundation
import MultiemuSupport
import Virtualization

/// Minimal Virtualization.framework Linux configuration, used as the Milestone 2
/// comparison baseline against QEMU + HVF.
///
/// Deliberately small: this is not a backend. It exists to answer two questions
/// with numbers rather than opinion — does a kernel boot under Apple's own VMM
/// on this Mac, and how long does it take — so that QEMU's boot time has
/// something to be compared against.
public enum VZLinuxPrototype {

    public struct Configuration: Sendable {
        public var kernelURL: URL
        public var initialRamdiskURL: URL?
        public var kernelCommandLine: String
        public var vcpuCount: Int
        public var memoryBytes: UInt64

        public init(
            kernelURL: URL,
            initialRamdiskURL: URL? = nil,
            // `console=hvc0` is what Virtualization.framework's virtio console
            // presents to a Linux guest; without it the boot is silent and a
            // stalled boot is indistinguishable from a failed one.
            kernelCommandLine: String = "console=hvc0",
            vcpuCount: Int = 2,
            memoryBytes: UInt64 = 2 * ByteCount.giB
        ) {
            self.kernelURL = kernelURL
            self.initialRamdiskURL = initialRamdiskURL
            self.kernelCommandLine = kernelCommandLine
            self.vcpuCount = vcpuCount
            self.memoryBytes = memoryBytes
        }
    }

    /// Builds a configuration and runs Apple's own validation over it.
    ///
    /// `consoleOutput` receives the guest serial stream. The caller owns the
    /// write end; nothing is buffered here.
    public static func makeConfiguration(
        _ configuration: Configuration,
        consoleOutput: FileHandle,
        consoleInput: FileHandle
    ) throws -> VZVirtualMachineConfiguration {
        let bootLoader = VZLinuxBootLoader(kernelURL: configuration.kernelURL)
        bootLoader.commandLine = configuration.kernelCommandLine
        if let ramdisk = configuration.initialRamdiskURL {
            bootLoader.initialRamdiskURL = ramdisk
        }

        let vmConfiguration = VZVirtualMachineConfiguration()
        vmConfiguration.bootLoader = bootLoader
        vmConfiguration.cpuCount = configuration.vcpuCount
        vmConfiguration.memorySize = configuration.memoryBytes

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: consoleInput,
            fileHandleForWriting: consoleOutput
        )
        vmConfiguration.serialPorts = [serial]
        vmConfiguration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        vmConfiguration.networkDevices = [network]

        try vmConfiguration.validate()
        return vmConfiguration
    }

    /// Whether this configuration supports `saveMachineStateTo`/`restoreMachineStateFrom`.
    /// Returns `nil` when the API is unavailable on the running macOS.
    public static func saveRestoreSupport(
        for configuration: VZVirtualMachineConfiguration
    ) -> Result<Void, any Error>? {
        guard #available(macOS 14.0, *) else { return nil }
        do {
            try configuration.validateSaveRestoreSupport()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
