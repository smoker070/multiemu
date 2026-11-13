import Foundation
import AppKit

// Auto-update from GitHub releases: on launch the app reads the latest release of
// smoker070/multiemu. When it is newer, the footer offers "Update now", which
// downloads the DMG, checks its SHA-256 against the digest GitHub publishes for
// the asset, swaps the app bundle and restarts.

let releasesAPI = URL(string: "https://api.github.com/repos/smoker070/multiemu/releases/latest")!

var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

/// "1.2.10" > "1.2.9"; a leading "v" is ignored.
func isNewer(_ a: String, than b: String) -> Bool {
    func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}

struct Release: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
    let tag_name: String
    let body: String?
    let assets: [Asset]
    var version: String { tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }
    var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
}

@MainActor
final class Updater: ObservableObject {
    @Published var available: Release?
    @Published var status = ""
    @Published var busy = false

    func check() async {
        var req = URLRequest(url: releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Multiemu/\(appVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rel = try? JSONDecoder().decode(Release.self, from: data),
              rel.dmg != nil, isNewer(rel.version, than: appVersion) else { return }
        available = rel
    }

    func install() async {
        guard let rel = available, let asset = rel.dmg else { return }
        busy = true; defer { busy = false }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("multiemu-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            status = "Downloading Multiemu \(rel.version)…"
            let (tmp, resp) = try await URLSession.shared.download(from: asset.browser_download_url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SetupError("Download failed.") }
            let dmg = work.appendingPathComponent(asset.name)
            try fm.moveItem(at: tmp, to: dmg)

            if let digest = asset.digest, digest.hasPrefix("sha256:") {
                let r = await runTool(URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256", dmg.path])
                let got = r.output.split(separator: " ").first.map(String.init) ?? ""
                guard got == String(digest.dropFirst(7)) else { throw SetupError("The download is damaged (checksum mismatch).") }
            }

            status = "Installing…"
            let mount = work.appendingPathComponent("mnt")
            let a = await runTool(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                  ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
            guard a.status == 0 else { throw SetupError("Could not open the update.") }
            let staged = work.appendingPathComponent("Multiemu.app")
            let c = await runTool(URL(fileURLWithPath: "/usr/bin/ditto"), [mount.appendingPathComponent("Multiemu.app").path, staged.path])
            _ = await runTool(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path, "-force"])
            guard c.status == 0, fm.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/Multiemu").path) else {
                throw SetupError("The update has no Multiemu app inside.")
            }

            // A detached helper waits for this app to quit, swaps the bundle, and
            // opens the new one. The old bundle goes to the Trash, not rm.
            let target = Bundle.main.bundleURL.path
            let script = """
            while kill -0 \(getpid()) 2>/dev/null; do sleep 0.3; done
            /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
            /usr/bin/osascript -e "tell application \\"Finder\\" to delete POSIX file \\"$1\\"" >/dev/null 2>&1 || mv "$1" "$1.old-$$"
            /usr/bin/ditto "$2" "$1" && /usr/bin/open "$1"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, "sh", target, staged.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            status = "Update failed: \(error.localizedDescription)"
        }
    }
}
