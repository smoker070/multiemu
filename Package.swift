// swift-tools-version:6.0
// Multiemu — Android emulator for macOS.
//
// The Swift package holds every piece of the product that is NOT AppKit/SwiftUI
// presentation code. The macOS application target (Milestone 17) links these
// libraries; the `multiemu-probe` CLI links them too, which keeps the core
// testable and runnable without an Xcode project.

import PackageDescription

let package = Package(
    name: "Multiemu",
    platforms: [
        // Product requirement: macOS 14 or later.
        .macOS(.v14)
    ],
    products: [
        .library(name: "MultiemuSupport", targets: ["MultiemuSupport"]),
        .library(name: "MultiemuHost", targets: ["MultiemuHost"]),
        .library(name: "MultiemuBackend", targets: ["MultiemuBackend"]),
        .executable(name: "Multiemu", targets: ["MultiemuApp"]),
        .executable(name: "multiemu-guest-service", targets: ["MultiemuGuestServiceCLI"]),
        .executable(name: "multiemu-perf", targets: ["MultiemuPerfCLI"]),
        .executable(name: "multiemu-adb", targets: ["MultiemuADBCLI"]),
        .executable(name: "multiemu-icon", targets: ["MultiemuIconGenerator"]),
        .executable(name: "multiemu-probe", targets: ["MultiemuProbe"]),
        .executable(name: "multiemu-hvprobe", targets: ["MultiemuHVProbe"]),
        .executable(name: "multiemu-vzprobe", targets: ["MultiemuVZProbe"]),
        .library(name: "MultiemuVZ", targets: ["MultiemuVZ"]),
        .library(name: "MultiemuQEMU", targets: ["MultiemuQEMU"]),
        .library(name: "MultiemuLifecycle", targets: ["MultiemuLifecycle"]),
        .library(name: "MultiemuDisks", targets: ["MultiemuDisks"]),
        .library(name: "MultiemuConfiguration", targets: ["MultiemuConfiguration"]),
        .library(name: "MultiemuImages", targets: ["MultiemuImages"]),
        .library(name: "MultiemuDBus", targets: ["MultiemuDBus"]),
        .library(name: "MultiemuGraphics", targets: ["MultiemuGraphics"]),
        .library(name: "MultiemuRecording", targets: ["MultiemuRecording"]),
        .library(name: "MultiemuCompatibility", targets: ["MultiemuCompatibility"]),
        .library(name: "MultiemuInput", targets: ["MultiemuInput"]),
        .library(name: "MultiemuGuestServices", targets: ["MultiemuGuestServices"]),
        .library(name: "MultiemuADB", targets: ["MultiemuADB"]),
        .library(name: "MultiemuViewModels", targets: ["MultiemuViewModels"]),
        .library(name: "MultiemuUI", targets: ["MultiemuUI"]),
        .executable(name: "multiemu-display-window", targets: ["MultiemuDisplayWindow"]),
        .executable(name: "multiemu-input-spike", targets: ["MultiemuInputSpike"]),
        .executable(name: "multiemu-network-spike", targets: ["MultiemuNetworkSpike"]),
        .executable(name: "multiemu-persistence-spike", targets: ["MultiemuPersistenceSpike"]),
        .executable(name: "multiemu-snapshot-spike", targets: ["MultiemuSnapshotSpike"]),
        .executable(name: "multiemu-image", targets: ["MultiemuImageCLI"]),
        .executable(name: "multiemu-device", targets: ["MultiemuDeviceCLI"]),
        .executable(name: "multiemu-multi-instance-spike", targets: ["MultiemuMultiInstanceSpike"]),
        .executable(name: "multiemu-input-mapping-spike", targets: ["MultiemuInputMappingSpike"]),
        .executable(name: "multiemu-display-control-spike", targets: ["MultiemuDisplayControlSpike"]),
        .executable(name: "multiemu-recording-spike", targets: ["MultiemuRecordingSpike"]),
        .executable(name: "multiemu-sharing-spike", targets: ["MultiemuSharingSpike"]),
        .executable(name: "multiemu-compat", targets: ["MultiemuCompatCLI"]),
        .executable(name: "multiemu-session", targets: ["MultiemuSessionCLI"]),
        .executable(name: "multiemu-display-spike", targets: ["MultiemuDisplaySpike"]),
        .executable(name: "multiemu-boot", targets: ["MultiemuBootCLI"]),
    ],
    dependencies: [
        // Intentionally empty.
        //
        // Every third-party dependency added here must first be entered in
        // docs/DEPENDENCIES-AND-LICENSING.md with its license and its
        // redistribution consequences for a signed, notarized, closed-source DMG.
        // Prefer Apple system frameworks (Network, Virtualization, Metal, os)
        // over source dependencies.
    ],
    targets: [
        .target(
            name: "MultiemuSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuHost",
            dependencies: ["MultiemuSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuBackend",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuADB"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuProbe",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuBackend"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuCompatibility",
            dependencies: ["MultiemuSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuRecording",
            dependencies: ["MultiemuSupport", "MultiemuGraphics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuInput",
            dependencies: ["MultiemuSupport", "MultiemuDBus", "MultiemuGraphics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuIconGenerator",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuApp",
            dependencies: ["MultiemuSupport", "MultiemuGraphics", "MultiemuUI",
                           "MultiemuViewModels", "MultiemuConfiguration", "MultiemuImages",
                           "MultiemuInput"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuViewModels",
            dependencies: ["MultiemuRecording", "MultiemuSupport", "MultiemuHost", "MultiemuBackend", "MultiemuQEMU",
                           "MultiemuDBus", "MultiemuGraphics", "MultiemuInput",
                           "MultiemuDisks", "MultiemuConfiguration", "MultiemuImages",
                           "MultiemuLifecycle", "MultiemuADB"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuUI",
            dependencies: ["MultiemuSupport", "MultiemuGraphics", "MultiemuInput"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuSnapshotSpike",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuBackend", "MultiemuQEMU",
                           "MultiemuDBus", "MultiemuGraphics", "MultiemuInput",
                           "MultiemuDisks", "MultiemuConfiguration"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuPersistenceSpike",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuBackend", "MultiemuQEMU",
                           "MultiemuDBus", "MultiemuGraphics", "MultiemuInput",
                           "MultiemuDisks", "MultiemuConfiguration"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuNetworkSpike",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuBackend", "MultiemuQEMU",
                           "MultiemuDBus", "MultiemuGraphics", "MultiemuInput"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuInputSpike",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuBackend", "MultiemuQEMU",
                           "MultiemuDBus", "MultiemuGraphics", "MultiemuInput"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuDisplayWindow",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuBackend", "MultiemuQEMU",
                           "MultiemuDBus", "MultiemuGraphics", "MultiemuUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuGraphics",
            dependencies: ["MultiemuSupport", "MultiemuDBus"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuDBus",
            dependencies: ["MultiemuSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuConfiguration",
            dependencies: ["MultiemuSupport", "MultiemuBackend", "MultiemuDisks", "MultiemuInput"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuDisks",
            dependencies: ["MultiemuSupport", "MultiemuBackend"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuGuestServices",
            dependencies: ["MultiemuSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuADB",
            dependencies: ["MultiemuSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuADBCLI",
            dependencies: ["MultiemuADB"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuImages",
            dependencies: ["MultiemuSupport", "MultiemuBackend", "MultiemuDisks"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuPerfCLI",
            dependencies: ["MultiemuQEMU", "MultiemuDBus", "MultiemuGraphics", "MultiemuBackend", "MultiemuGuestServices", "MultiemuInput", "MultiemuSupport", "MultiemuADB"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuGuestServiceCLI",
            dependencies: ["MultiemuGuestServices"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuCompatCLI",
            dependencies: ["MultiemuCompatibility", "MultiemuHost", "MultiemuSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuSharingSpike",
            dependencies: ["MultiemuSupport", "MultiemuBackend", "MultiemuQEMU", "MultiemuDBus",
                           "MultiemuGraphics", "MultiemuInput", "MultiemuHost"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuRecordingSpike",
            dependencies: ["MultiemuSupport", "MultiemuBackend", "MultiemuQEMU", "MultiemuDBus",
                           "MultiemuGraphics", "MultiemuInput", "MultiemuHost",
                           "MultiemuConfiguration", "MultiemuRecording"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuDisplayControlSpike",
            dependencies: ["MultiemuSupport", "MultiemuBackend", "MultiemuQEMU", "MultiemuDBus",
                           "MultiemuGraphics", "MultiemuInput", "MultiemuHost", "MultiemuConfiguration"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuInputMappingSpike",
            dependencies: ["MultiemuSupport", "MultiemuBackend", "MultiemuQEMU", "MultiemuDBus",
                           "MultiemuGraphics", "MultiemuInput", "MultiemuDisks", "MultiemuHost"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuMultiInstanceSpike",
            dependencies: ["MultiemuSupport", "MultiemuBackend", "MultiemuQEMU", "MultiemuDisks",
                           "MultiemuConfiguration", "MultiemuHost", "MultiemuLifecycle"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuDeviceCLI",
            dependencies: ["MultiemuSupport", "MultiemuBackend", "MultiemuDisks", "MultiemuConfiguration"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuImageCLI",
            dependencies: ["MultiemuSupport", "MultiemuBackend", "MultiemuImages"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuLifecycle",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuBackend"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuDisplaySpike",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuBackend", "MultiemuQEMU", "MultiemuDBus", "MultiemuGraphics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuSessionCLI",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuBackend", "MultiemuQEMU", "MultiemuLifecycle"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuQEMU",
            dependencies: ["MultiemuSupport", "MultiemuBackend", "MultiemuDisks", "MultiemuGuestServices"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuBootCLI",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuBackend", "MultiemuQEMU"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MultiemuVZ",
            dependencies: ["MultiemuSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuVZProbe",
            dependencies: ["MultiemuSupport", "MultiemuHost", "MultiemuVZ"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MultiemuHVProbe",
            dependencies: ["MultiemuSupport", "MultiemuHost"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("Hypervisor")]
        ),
        .testTarget(
            name: "MultiemuSupportTests",
            dependencies: ["MultiemuSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuGuestServicesTests",
            dependencies: ["MultiemuGuestServices"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuADBTests",
            dependencies: ["MultiemuADB"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuHostTests",
            dependencies: ["MultiemuHost"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuBackendTests",
            dependencies: ["MultiemuBackend"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuInputTests",
            dependencies: ["MultiemuInput"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuCompatibilityTests",
            dependencies: ["MultiemuCompatibility"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuRecordingTests",
            dependencies: ["MultiemuRecording", "MultiemuGraphics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuGraphicsTests",
            dependencies: ["MultiemuGraphics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuConfigurationTests",
            dependencies: ["MultiemuConfiguration", "MultiemuInput"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuDBusTests",
            dependencies: ["MultiemuDBus", "MultiemuSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuImagesTests",
            dependencies: ["MultiemuImages", "MultiemuDisks"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuViewModelsTests",
            dependencies: ["MultiemuViewModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuLifecycleTests",
            dependencies: ["MultiemuLifecycle"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MultiemuQEMUTests",
            dependencies: ["MultiemuQEMU"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
