import Foundation
import SwiftUI

// First-run setup: Multiemu drives Google's Android emulator and does not ship it.
// On a Mac without the Android SDK it downloads Google's command-line tools (and a
// Java runtime if there is none), asks the person to accept Google's licences,
// then installs the emulator and platform-tools. Android Studio users already
// have all of this in ~/Library/Android/sdk and never see the setup.

/// Pinned so every install gets the same tools; sdkmanager updates itself later.
let cmdlineToolsURL = URL(string: "https://dl.google.com/android/repository/commandlinetools-mac-15641748_latest.zip")!
/// Eclipse Temurin 17 JRE for Apple Silicon (redirects to the latest 17.x build).
let jreURL = URL(string: "https://api.adoptium.net/v3/binary/latest/17/ga/mac/aarch64/jre/hotspot/normal/eclipse")!

private let javaCache = LockedString()

func findJavaHome() -> String? {
    if !javaCache.value.isEmpty { return javaCache.value }
    let fm = FileManager.default
    // Tests of the first-run setup pretend the Mac has no Java at all.
    if ProcessInfo.processInfo.environment["MULTIEMU_TEST_NO_JAVA"] != nil {
        let own = supportURL.appendingPathComponent("jre/Contents/Home").path
        return fm.isExecutableFile(atPath: own + "/bin/java") ? own : nil
    }
    var candidates = [
        supportURL.appendingPathComponent("jre/Contents/Home").path,
        "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
        "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home",
        "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
    ]
    // A JDK installed system-wide (Temurin, Zulu, Oracle...). /usr/libexec/java_home
    // fails cleanly when there is none.
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
    p.arguments = ["-v", "17+"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    if (try? p.run()) != nil {
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if p.terminationStatus == 0 { candidates.append(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0 + "/bin/java") }) else { return nil }
    javaCache.set(found)
    return found
}

enum SetupState: Equatable { case ready, missing }

func sdkState() -> SetupState {
    let fm = FileManager.default
    let need = [emulatorURL, avdManagerURL, sdkManagerURL, sdkURL.appendingPathComponent("platform-tools/adb")]
    return need.allSatisfy { fm.isExecutableFile(atPath: $0.path) } && findJavaHome() != nil ? .ready : .missing
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var state = sdkState()
    @Published var running = false
    @Published var failed = false
    @Published var lines: [String] = []

    private func log(_ s: String) { lines.append(s); if lines.count > 300 { lines.removeFirst(80) } }

    private func download(_ url: URL, to dest: URL) async throws {
        log("Downloading \(url.host ?? "")…")
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// The person pressed "Accept and install" after reading the licence links.
    func install() async {
        running = true; failed = false; lines = []
        defer { running = false; state = sdkState() }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: sdkURL, withIntermediateDirectories: true)

            if findJavaHome() == nil {
                let tgz = supportURL.appendingPathComponent("jre.tar.gz")
                try await download(jreURL, to: tgz)
                let unpack = supportURL.appendingPathComponent("jre-unpack")
                try? fm.removeItem(at: unpack); try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
                let r = await runTool(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", tgz.path, "-C", unpack.path])
                guard r.status == 0, let top = try fm.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil)
                        .first(where: { $0.lastPathComponent.hasPrefix("jdk") }) else { throw SetupError("Could not unpack Java.") }
                let jre = supportURL.appendingPathComponent("jre")
                try? fm.removeItem(at: jre); try fm.moveItem(at: top, to: jre)
                try? fm.removeItem(at: unpack); try? fm.removeItem(at: tgz)
                javaCache.set("")
                guard findJavaHome() != nil else { throw SetupError("Java did not install.") }
                log("Java ready.")
            }

            if !fm.isExecutableFile(atPath: sdkManagerURL.path) {
                let zip = supportURL.appendingPathComponent("cmdline-tools.zip")
                try await download(cmdlineToolsURL, to: zip)
                let unpack = supportURL.appendingPathComponent("tools-unpack")
                try? fm.removeItem(at: unpack)
                let r = await runTool(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpack.path])
                guard r.status == 0 else { throw SetupError("Could not unpack the Android tools.") }
                // The zip holds "cmdline-tools/"; sdkmanager expects it at cmdline-tools/latest.
                let latest = sdkURL.appendingPathComponent("cmdline-tools/latest")
                try fm.createDirectory(at: latest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: latest)
                try fm.moveItem(at: unpack.appendingPathComponent("cmdline-tools"), to: latest)
                try? fm.removeItem(at: unpack); try? fm.removeItem(at: zip)
                log("Android command-line tools ready.")
            }

            log("Accepting the Android SDK licences…")
            _ = await runTool(sdkManagerURL, ["--sdk_root=\(sdkURL.path)", "--licenses"], stdin: String(repeating: "y\n", count: 30))
            log("Installing the emulator and platform-tools (about 1.4 GB)…")
            let r = await runTool(sdkManagerURL, ["--sdk_root=\(sdkURL.path)", "emulator", "platform-tools"]) { line in
                Task { @MainActor in self.log(line) }
            }
            guard r.status == 0, sdkState() == .ready else { throw SetupError("The emulator did not install. Exit \(r.status).") }
            log("Done. Press New to create your first Android device.")
        } catch {
            log("Failed: \(error.localizedDescription)"); failed = true
        }
    }
}

struct SetupError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct SetupView: View {
    @ObservedObject var setup: SetupModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox").font(.system(size: 30)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up the Android emulator").font(.title2.bold())
                    Text("One time, about 1.5 GB. Each Android version you create later downloads about 1.5 GB.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Multiemu runs Google's official Android emulator. It is not on this Mac yet, so Multiemu will download into `~/Library/Android/sdk`:")
            VStack(alignment: .leading, spacing: 4) {
                Label("Android SDK command-line tools, emulator and platform-tools (Google)", systemImage: "checkmark")
                Label("A Java runtime for those tools, if this Mac has none (Eclipse Temurin 17)", systemImage: "checkmark")
            }.foregroundStyle(.secondary)
            Text("By installing you accept Google's [Android SDK License Agreement](https://developer.android.com/studio/terms) and the Android system image licences.")
                .font(.callout).tint(accent).fixedSize(horizontal: false, vertical: true)

            if !setup.lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(setup.lines.enumerated()), id: \.offset) { i, l in
                                Text(l).font(.system(.caption, design: .monospaced)).id(i)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: setup.lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
                .padding(8).background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .frame(height: 160)
            }

            HStack {
                if setup.running { ProgressView().controlSize(.small); Text("Installing…").foregroundStyle(.secondary) }
                else if setup.failed { Label("Setup failed. Check your connection and try again.", systemImage: "xmark.octagon").foregroundStyle(.red) }
                Spacer()
                if setup.state == .ready && !setup.running {
                    Button("Continue") { onDone() }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction)
                } else {
                    Button(setup.failed ? "Try again" : "Accept and install") { Task { await setup.install() } }
                        .buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction)
                        .disabled(setup.running)
                }
            }
        }
        .padding(24).frame(width: 600)
        .interactiveDismissDisabled(true)
    }
}
