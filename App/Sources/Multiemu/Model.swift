import Foundation
import SwiftUI

// MARK: - Paths

let homeURL = FileManager.default.homeDirectoryForCurrentUser
/// Google's standard SDK location (the one Android Studio uses). MULTIEMU_SDK_ROOT
/// overrides it, which is how the first-run setup is tested on a clean folder.
let sdkURL = ProcessInfo.processInfo.environment["MULTIEMU_SDK_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? homeURL.appendingPathComponent("Library/Android/sdk")
let supportURL = ProcessInfo.processInfo.environment["MULTIEMU_SUPPORT"].map { URL(fileURLWithPath: $0) }
    ?? homeURL.appendingPathComponent("Library/Application Support/Multiemu")
let avdRootURL = homeURL.appendingPathComponent(".android/avd")
let emulatorURL = sdkURL.appendingPathComponent("emulator/emulator")
let avdManagerURL = sdkURL.appendingPathComponent("cmdline-tools/latest/bin/avdmanager")
let sdkManagerURL = sdkURL.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager")
/// Java is needed only by Google's sdkmanager/avdmanager (Java 17 or newer).
var javaHome: String { findJavaHome() ?? "" }
let logsURL = homeURL.appendingPathComponent("Library/Logs")

// MARK: - Android versions

struct AndroidVersion: Identifiable, Hashable {
    let api: Int
    let name: String
    var id: Int { api }
    var title: String { "Android \(name)" }
}

let androidVersions: [AndroidVersion] = [
    .init(api: 28, name: "9"), .init(api: 29, name: "10"), .init(api: 30, name: "11"),
    .init(api: 31, name: "12"), .init(api: 32, name: "12L"), .init(api: 33, name: "13"),
    .init(api: 34, name: "14"), .init(api: 35, name: "15"),
]

func versionName(_ api: Int) -> String {
    androidVersions.first { $0.api == api }?.name ?? "API \(api)"
}

enum Kind: String, CaseIterable, Identifiable {
    case playStore = "Play Store"
    case playStoreRoot = "Play Store + Root"
    case root = "Root"
    var id: String { rawValue }
    /// Google's image tag. "google_apis" is a userdebug build, so `adb root`
    /// works; "google_apis_playstore" is a production build with Play Store.
    var tag: String { self == .root ? "google_apis" : "google_apis_playstore" }
    var isRooted: Bool { self != .playStore }
    var blurb: String {
        switch self {
        case .playStore: return "Google Play and Chrome. Not rooted."
        case .playStoreRoot: return "Google Play and Chrome, rooted with Magisk (`su`). Apps may detect root."
        case .root: return "Google's userdebug build: `adb root` and a writable /system. No Play Store app."
        }
    }
}

/// Marks a Play Store device that boots the Magisk ramdisk. Kept per device, so
/// rooted and plain Play Store devices of one Android version can coexist.
func rootFlagURL(_ avdDir: URL) -> URL { avdDir.appendingPathComponent("android-manager-root") }
func magiskRamdiskURL(api: Int) -> URL { imageDir(api: api, tag: Kind.playStore.tag).appendingPathComponent("ramdisk-magisk.img") }
func magiskReady(api: Int) -> Bool { FileManager.default.fileExists(atPath: magiskRamdiskURL(api: api).path) }

/// What was actually tested for "Play Store + Root" (Magisk via rootAVD), per API.
/// 31 (Android 12): su works. 28 (Android 9): the patched boot image builds but
/// Magisk never starts, so `su` does not exist. Others are untested.
let rootVerified: [Int: Bool] = [31: true, 28: false]

let ramOptions = [1024, 2048, 3072, 4096, 6144, 8192]
let coreOptions = [1, 2, 3, 4, 6, 8]

func imageDir(api: Int, tag: String) -> URL {
    sdkURL.appendingPathComponent("system-images/android-\(api)/\(tag)/arm64-v8a")
}
func imageInstalled(api: Int, kind: Kind) -> Bool {
    FileManager.default.fileExists(atPath: imageDir(api: api, tag: kind.tag).appendingPathComponent("system.img").path)
}

// MARK: - Resolution presets

struct Resolution: Identifiable, Hashable {
    let label: String
    let width: Int, height: Int, density: Int
    var id: String { label }
}
let resolutions: [Resolution] = [
    .init(label: "Phone 1080 × 2400 (420 dpi)", width: 1080, height: 2400, density: 420),
    .init(label: "Phone 720 × 1600 (320 dpi)", width: 720, height: 1600, density: 320),
    .init(label: "Tablet 1280 × 800 (240 dpi)", width: 800, height: 1280, density: 240),
    .init(label: "Tablet 1600 × 2560 (320 dpi)", width: 1600, height: 2560, density: 320),
    .init(label: "Widescreen 1920 × 1080 (240 dpi)", width: 1920, height: 1080, density: 240),
]

// MARK: - Instance

struct Instance: Identifiable, Hashable {
    let id: String               // AVD name, also the folder name
    var displayName: String
    var api: Int
    var kind: Kind
    var ramMB: Int
    var cores: Int
    var width: Int, height: Int, density: Int
    var dir: URL
    var running = false
    var pid: Int32?
    var diskBytes: Int64?

    var androidLabel: String { "Android \(versionName(api))" }
    var typeLabel: String { kind.rawValue }
    var resolutionLabel: String { "\(width) × \(height)" }
}

// MARK: - Shell helpers

struct ToolResult { let status: Int32; let output: String }

func toolEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["ANDROID_SDK_ROOT"] = sdkURL.path
    env["ANDROID_HOME"] = sdkURL.path
    if !javaHome.isEmpty { env["JAVA_HOME"] = javaHome } else { env.removeValue(forKey: "JAVA_HOME") }
    env["PATH"] = (javaHome.isEmpty ? "" : "\(javaHome)/bin:") + "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    return env
}

/// Runs a tool to completion on a background thread and returns its output.
/// `onLine` receives progress as it is produced (sdkmanager redraws with \r).
func runTool(_ url: URL, _ args: [String], stdin: String? = nil,
             cwd: URL? = nil, env: [String: String] = [:], timeout: TimeInterval? = nil,
             onLine: (@Sendable (String) -> Void)? = nil) async -> ToolResult {
    await Task.detached {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.environment = toolEnvironment().merging(env) { $1 }
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let input = Pipe()
        p.standardInput = input
        let collected = LockedString()
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            collected.append(s)
            if let onLine {
                for piece in s.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                    let t = piece.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { onLine(t) }
                }
            }
        }
        do { try p.run() } catch { return ToolResult(status: -1, output: "\(error)") }
        if let timeout {
            // A tool that never answers (for example `su` waiting for a grant)
            // must not hang the whole job.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        return ToolResult(status: p.terminationStatus, output: collected.value)
    }.value
}

final class LockedString: @unchecked Sendable {
    private var s = ""
    private let lock = NSLock()
    func append(_ x: String) { lock.lock(); s += x; lock.unlock() }
    func set(_ x: String) { lock.lock(); s = x; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return s }
}

// MARK: - config.ini

func parseIni(_ url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var d: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        d[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] =
            String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
    }
    return d
}

/// Edits keys in place and leaves every other line untouched.
func editIni(_ url: URL, set: [String: String], remove: Set<String> = []) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    var seen = Set<String>()
    var out: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let key = line.firstIndex(of: "=").map { String(line[..<$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        if remove.contains(key) { continue }
        if let v = set[key] { out.append("\(key)=\(v)"); seen.insert(key) } else { out.append(String(line)) }
    }
    while out.last == "" { out.removeLast() }
    for (k, v) in set where !seen.contains(k) { out.append("\(k)=\(v)") }
    try (out.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

func sanitizedID(_ s: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    let cleaned = String(s.map { allowed.contains($0) ? $0 : "_" })
    return cleaned.isEmpty ? "Android" : cleaned
}
