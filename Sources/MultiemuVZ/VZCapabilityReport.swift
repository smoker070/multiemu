import Foundation
import ObjectiveC.runtime
import Virtualization

/// Runtime introspection of Virtualization.framework.
///
/// Milestone 2 needs to settle whether Virtualization.framework could ever be
/// the shipping Android backend. Two of the arguments against it —
/// "virtio-gpu is 2D only" and "there is no way to attach a renderer" — are
/// claims about API surface, and API surface is a fact we can read off the
/// running system instead of guessing at.
///
/// Virtualization.framework classes are Objective-C, so `class_copyPropertyList`
/// returns the complete public configuration surface for the macOS version we
/// are actually running on. That makes the result evidence rather than
/// recollection, and it re-verifies itself on every future macOS release.
public enum VZCapabilityReport {

    public struct ClassSurface: Sendable, Equatable {
        public var className: String
        public var exists: Bool
        public var properties: [String]

        public init(className: String, exists: Bool, properties: [String]) {
            self.className = className
            self.exists = exists
            self.properties = properties
        }
    }

    /// Classes whose presence or absence changes a Multiemu design decision.
    public static let classesOfInterest: [String] = [
        // Boot
        "VZLinuxBootLoader",
        "VZEFIBootLoader",
        // Graphics — the decisive area
        "VZVirtioGraphicsDeviceConfiguration",
        "VZVirtioGraphicsScanoutConfiguration",
        "VZMacGraphicsDeviceConfiguration",
        "VZGraphicsDisplayConfiguration",
        // Storage
        "VZVirtioBlockDeviceConfiguration",
        "VZDiskImageStorageDeviceAttachment",
        "VZNVMExpressControllerDeviceConfiguration",
        // Transport / IO
        "VZVirtioSocketDeviceConfiguration",
        "VZVirtioConsoleDeviceConfiguration",
        "VZVirtioConsoleDeviceSerialPortConfiguration",
        "VZSpiceAgentPortAttachment",
        "VZVirtioFileSystemDeviceConfiguration",
        "VZVirtioEntropyDeviceConfiguration",
        "VZVirtioTraditionalMemoryBalloonDeviceConfiguration",
        // Network
        "VZNATNetworkDeviceAttachment",
        "VZBridgedNetworkDeviceAttachment",
        "VZVirtioNetworkDeviceConfiguration",
        // Audio
        "VZVirtioSoundDeviceConfiguration",
        "VZVirtioSoundDeviceOutputStreamConfiguration",
        "VZVirtioSoundDeviceInputStreamConfiguration",
        // Input / USB
        "VZUSBKeyboardConfiguration",
        "VZUSBScreenCoordinatePointingDeviceConfiguration",
        "VZXHCIControllerConfiguration",
        // Platform
        "VZGenericPlatformConfiguration",
        "VZLinuxRosettaDirectoryShare",
    ]

    /// Properties on a class that would indicate an attachable or 3D-capable
    /// renderer. Searched case-insensitively across the whole surface.
    public static let rendererIndicators = [
        "3d", "accel", "render", "virgl", "venus", "gfxstream", "opengl", "metal", "gpu",
    ]

    public static func surface(of className: String) -> ClassSurface {
        guard let cls: AnyClass = NSClassFromString(className) else {
            return ClassSurface(className: className, exists: false, properties: [])
        }
        var count: UInt32 = 0
        guard let list = class_copyPropertyList(cls, &count) else {
            return ClassSurface(className: className, exists: true, properties: [])
        }
        defer { free(list) }
        let names = (0..<Int(count))
            .map { String(cString: property_getName(list[$0])) }
            .sorted()
        return ClassSurface(className: className, exists: true, properties: names)
    }

    public static func allSurfaces() -> [ClassSurface] {
        classesOfInterest.map(surface(of:))
    }

    /// Selectors on a class matching a substring. Used to confirm that
    /// save/restore actually exists on `VZVirtualMachine` for this macOS.
    public static func methods(of className: String, containing needle: String) -> [String] {
        guard let cls: AnyClass = NSClassFromString(className) else { return [] }
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count))
            .map { String(cString: sel_getName(method_getName(list[$0]))) }
            .filter { $0.range(of: needle, options: .caseInsensitive) != nil }
            .sorted()
    }

    /// Any property across the graphics classes that suggests a 3D or
    /// attachable-renderer capability. An empty result is the evidence that
    /// no such capability is exposed.
    public static func rendererRelatedProperties() -> [String] {
        let graphicsClasses = [
            "VZVirtioGraphicsDeviceConfiguration",
            "VZVirtioGraphicsScanoutConfiguration",
            "VZGraphicsDeviceConfiguration",
        ]
        var found: [String] = []
        for className in graphicsClasses {
            for property in surface(of: className).properties {
                let lowered = property.lowercased()
                if rendererIndicators.contains(where: { lowered.contains($0) }) {
                    found.append("\(className).\(property)")
                }
            }
        }
        return found
    }
}
