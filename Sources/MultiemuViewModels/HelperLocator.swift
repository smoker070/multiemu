import Foundation
import MultiemuBackend
import MultiemuDisks
import MultiemuSupport

/// Finds the executables Multiemu spawns.
///
/// A shipping build uses the signed helpers inside the application bundle. A
/// development build falls back to Homebrew, and says which it used — "it works
/// on my machine but not in the DMG" is exactly the failure this makes visible.
public struct HelperLocator: Sendable {

    public enum Source: String, Sendable {
        case bundledHelper
        case developmentInstall
        case missing
    }

    public struct Resolution: Sendable {
        public var url: URL?
        public var source: Source
        public var searchedPaths: [String]

        public var isAvailable: Bool { url != nil }
    }

    public let bundleHelpersDirectory: URL?

    public init(bundleHelpersDirectory: URL? = HelperLocator.defaultBundleHelpers()) {
        self.bundleHelpersDirectory = bundleHelpersDirectory
    }

    /// `Multiemu.app/Contents/Helpers`, when running from a bundle.
    public static func defaultBundleHelpers() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        // …/Contents/MacOS/Multiemu -> …/Contents/Helpers
        let helpers = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true)
        return FileManager.default.fileExists(atPath: helpers.path) ? helpers : nil
    }

    private static let developmentPrefixes = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Overrides the whole search with a single directory.
    ///
    /// Intended for pointing at a locally built QEMU (see `scripts/build-qemu.sh`)
    /// and for exercising the "helpers missing" path. It does not widen the
    /// attack surface: setting another process's environment already requires
    /// running as that user, and the guest cannot reach the host environment.
    public static let overrideVariable = "MULTIEMU_HELPER_DIR"

    public func locate(_ name: String) -> Resolution {
        var searched: [String] = []

        if let override = ProcessInfo.processInfo.environment[Self.overrideVariable],
           !override.isEmpty {
            let candidate = (override as NSString).appendingPathComponent(name)
            searched.append(candidate)
            guard FileManager.default.isExecutableFile(atPath: candidate) else {
                return Resolution(url: nil, source: .missing, searchedPaths: searched)
            }
            return Resolution(url: URL(fileURLWithPath: candidate),
                              source: .developmentInstall, searchedPaths: searched)
        }

        if let bundleHelpersDirectory {
            let candidate = bundleHelpersDirectory.appendingPathComponent(name)
            searched.append(candidate.path)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return Resolution(url: candidate, source: .bundledHelper, searchedPaths: searched)
            }
        }
        for prefix in Self.developmentPrefixes {
            let candidate = (prefix as NSString).appendingPathComponent(name)
            searched.append(candidate)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return Resolution(url: URL(fileURLWithPath: candidate),
                                  source: .developmentInstall, searchedPaths: searched)
            }
        }
        return Resolution(url: nil, source: .missing, searchedPaths: searched)
    }

    public func locateEmulator(for architecture: GuestArchitecture) -> Resolution {
        locate(architecture == .arm64 ? "qemu-system-aarch64" : "qemu-system-x86_64")
    }

    public func locateDiskTool() -> Resolution { locate("qemu-img") }

    public func diskManager() -> VirtualDiskManager? {
        locateDiskTool().url.map(VirtualDiskManager.init(toolURL:))
    }
}
