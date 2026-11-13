// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Multiemu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Multiemu", path: "Sources/Multiemu")
    ]
)
