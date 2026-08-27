import Foundation

/// Locates the external executables later milestones depend on.
///
/// Multiemu never shells out to a tool it found on `PATH` at runtime in a
/// shipping build — bundled, signed copies are used instead (see
/// docs/DEPENDENCIES-AND-LICENSING.md). This probe exists for two reasons:
/// developer-machine bootstrap checks, and diagnostics ("the user has a
/// conflicting Homebrew QEMU on PATH" is a real support case).
public enum ExternalToolProbe {

    /// Directories searched in addition to `PATH`.
    /// GUI applications launched from Finder inherit a minimal `PATH` that
    /// excludes both Homebrew prefixes, so they are probed explicitly.
    private static let additionalSearchPaths = [
        "/opt/homebrew/bin",   // Homebrew on Apple Silicon
        "/usr/local/bin",      // Homebrew on Intel
        "/usr/bin",
        "/bin",
        "/usr/sbin",
    ]

    struct Definition: Sendable {
        var name: String
        var purpose: String
        var requiredFromMilestone: String
        var versionArguments: [String]?
        var installHint: String
    }

    /// The tools the roadmap actually needs, each tagged with the milestone
    /// that first requires it. Nothing here is required for Milestone 1.
    static let definitions: [Definition] = [
        Definition(
            name: "qemu-system-aarch64",
            purpose: "primary emulator backend for ARM64 Android guests",
            requiredFromMilestone: "M2 (backend proof of concept)",
            versionArguments: ["--version"],
            installHint: "Development only: `brew install qemu`. Shipping builds use a bundled, signed QEMU built by scripts/build-qemu.sh."
        ),
        Definition(
            name: "qemu-system-x86_64",
            purpose: "emulator backend for x86_64 Android guests on Intel hosts",
            requiredFromMilestone: "M2 (backend proof of concept)",
            versionArguments: ["--version"],
            installHint: "Development only: `brew install qemu`."
        ),
        Definition(
            name: "qemu-img",
            purpose: "creating and inspecting qcow2 virtual disks",
            requiredFromMilestone: "M9 (persistent userdata)",
            versionArguments: ["--version"],
            installHint: "Development only: `brew install qemu`."
        ),
        Definition(
            name: "adb",
            purpose: "guest shell, APK installation, boot-state verification",
            requiredFromMilestone: "M8 (ADB integration)",
            versionArguments: ["version"],
            installHint: "Development only: `brew install --cask android-platform-tools`. Shipping builds use an ADB client built from AOSP sources (Apache-2.0), not the Google-distributed binary."
        ),
        Definition(
            name: "python3",
            purpose: "image tooling and build scripts",
            requiredFromMilestone: "M4 (Android guest boot)",
            versionArguments: ["--version"],
            installHint: "Included with the Xcode Command Line Tools."
        ),
        Definition(
            name: "ninja",
            purpose: "building QEMU and gfxstream from source",
            requiredFromMilestone: "M2 (backend proof of concept)",
            versionArguments: ["--version"],
            installHint: "`brew install ninja`."
        ),
        Definition(
            name: "meson",
            purpose: "configuring QEMU and gfxstream builds",
            requiredFromMilestone: "M2 (backend proof of concept)",
            versionArguments: ["--version"],
            installHint: "`brew install meson`."
        ),
    ]

    static func collect(runVersionCommands: Bool = true) -> [ExternalTool] {
        definitions.map { definition in
            let path = resolve(definition.name)
            var version: String?
            if runVersionCommands, let path, let arguments = definition.versionArguments {
                version = firstLineOfOutput(executable: path, arguments: arguments)
            }
            return ExternalTool(
                name: definition.name,
                purpose: definition.purpose,
                requiredFromMilestone: definition.requiredFromMilestone,
                resolvedPath: path,
                version: version,
                installHint: definition.installHint
            )
        }
    }

    /// Resolves an executable name against `PATH` plus both Homebrew prefixes.
    ///
    /// Public because the Milestone 2 boot experiment needs to find a developer
    /// QEMU. Shipping builds resolve bundled helpers by explicit bundle path and
    /// must not use this.
    public static func resolve(_ executable: String) -> String? {
        let pathVariable = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchPaths = pathVariable.split(separator: ":").map(String.init) + additionalSearchPaths

        var seen = Set<String>()
        for directory in searchPaths where seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Runs `executable arguments` and returns its first output line.
    ///
    /// Guest-provided data never reaches this function: the executable path is
    /// resolved from a fixed allow-list of names above, arguments are literals,
    /// and no shell is involved (`Process` with `executableURL` performs no word
    /// splitting or expansion).
    private static func firstLineOfOutput(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text
            .split(separator: "\n")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
