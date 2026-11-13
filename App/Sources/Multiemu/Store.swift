import Foundation
import SwiftUI
import Darwin

@MainActor
final class InstanceStore: ObservableObject {
    @Published var instances: [Instance] = []
    @Published var notice: String = ""
    @Published var progress: [String] = []        // live log of a long job
    @Published var jobTitle: String = ""
    @Published var jobRunning = false
    @Published var jobFailed = false

    private var diskCache: [String: Int64] = [:]
    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }
    }

    // MARK: Reading

    func reload() {
        let fm = FileManager.default
        let inis = ((try? fm.contentsOfDirectory(at: avdRootURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "ini" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var list: [Instance] = []
        for ini in inis {
            let id = ini.deletingPathExtension().lastPathComponent
            let meta = parseIni(ini)
            let dir = URL(fileURLWithPath: meta["path"] ?? avdRootURL.appendingPathComponent("\(id).avd").path)
            let cfg = parseIni(dir.appendingPathComponent("config.ini"))
            guard !cfg.isEmpty else { continue }

            // image.sysdir.1 = system-images/android-31/google_apis_playstore/arm64-v8a/
            let parts = (cfg["image.sysdir.1"] ?? "").split(separator: "/").map(String.init)
            let api = parts.count > 1 ? Int(parts[1].replacingOccurrences(of: "android-", with: "")) ?? 0 : 0
            let tag = parts.count > 2 ? parts[2] : ""
            let flagged = fm.fileExists(atPath: rootFlagURL(dir).path)
            let kind: Kind = tag == "google_apis" ? .root : (flagged ? .playStoreRoot : .playStore)

            let ramRaw = cfg["hw.ramSize"] ?? "2048"
            let ram = ramRaw.hasSuffix("G") ? (Int(ramRaw.dropLast()) ?? 2) * 1024 : Int(ramRaw) ?? 2048

            var inst = Instance(
                id: id,
                displayName: cfg["avd.ini.displayname"] ?? id,
                api: api, kind: kind,
                ramMB: ram, cores: Int(cfg["hw.cpu.ncore"] ?? "") ?? 2,
                width: Int(cfg["hw.lcd.width"] ?? "") ?? 1080,
                height: Int(cfg["hw.lcd.height"] ?? "") ?? 2400,
                density: Int(cfg["hw.lcd.density"] ?? "") ?? 420,
                dir: dir)
            inst.diskBytes = diskCache[id]
            if let old = instances.first(where: { $0.id == id }) {
                inst.running = old.running; inst.pid = old.pid
            }
            list.append(inst)
        }
        instances = list
        refreshRunning()
        measureDisks()
    }

    func refreshRunning() {
        Task.detached {
            let r = Process()
            r.executableURL = URL(fileURLWithPath: "/bin/ps")
            r.arguments = ["-Ao", "pid=,command="]
            let pipe = Pipe(); r.standardOutput = pipe
            guard (try? r.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            r.waitUntilExit()
            var found: [String: Int32] = [:]
            for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
                guard line.contains("qemu-system-aarch64"), line.contains(" -avd ") else { continue }
                let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
                guard let i = tokens.firstIndex(of: "-avd"), i + 1 < tokens.count,
                      let pid = Int32(tokens[0]) else { continue }
                found[String(tokens[i + 1])] = pid
            }
            if !found.isEmpty {
                let a = Process(); a.executableURL = sdkURL.appendingPathComponent("platform-tools/adb")
                a.arguments = ["devices"]; let ap = Pipe(); a.standardOutput = ap; a.standardError = ap
                if (try? a.run()) != nil {
                    let t = String(data: ap.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    a.waitUntilExit()
                    if t.contains("\toffline") {
                        let r = Process(); r.executableURL = a.executableURL; r.arguments = ["reconnect", "offline"]
                        r.standardOutput = FileHandle.nullDevice; r.standardError = FileHandle.nullDevice
                        try? r.run(); r.waitUntilExit()
                    }
                }
            }
            await MainActor.run { [found] in
                for idx in self.instances.indices {
                    let id = self.instances[idx].id
                    let pid = found[id]
                    if self.instances[idx].running != (pid != nil) || self.instances[idx].pid != pid {
                        self.instances[idx].running = pid != nil
                        self.instances[idx].pid = pid
                    }
                }
            }
        }
    }

    private func measureDisks() {
        for inst in instances where diskCache[inst.id] == nil {
            let id = inst.id, dir = inst.dir
            Task.detached {
                let r = await runTool(URL(fileURLWithPath: "/usr/bin/du"), ["-sk", dir.path])
                // A failed or interrupted du must not show a device as empty.
                guard r.status == 0, let kb = Int64(r.output.split(separator: "\t").first.map(String.init) ?? ""), kb > 0 else { return }
                await MainActor.run {
                    self.diskCache[id] = kb * 1024
                    if let i = self.instances.firstIndex(where: { $0.id == id }) {
                        self.instances[i].diskBytes = kb * 1024
                    }
                }
            }
        }
    }

    // MARK: Start / stop

    func start(_ inst: Instance) { launch(inst) }

    /// `extra` carries flags for setup runs (for example `-no-snapshot`).
    @discardableResult
    func launch(_ inst: Instance, extra: [String] = []) -> Bool {
        guard !inst.running else { return false }
        var args = ["-avd", inst.id, "-no-boot-anim", "-no-metrics"]
        switch inst.kind {
        case .root:
            // A writable /system makes `adb remount` work at once. That needs a
            // cold boot, so these take about a minute.
            args += ["-writable-system", "-no-snapshot-load"]
        case .playStoreRoot:
            // Root lives in this per-device ramdisk, not in the shared image, so
            // plain Play Store devices of the same version stay unrooted.
            guard magiskReady(api: inst.api) else {
                notice = "\(inst.displayName): the root boot image is missing."; return false
            }
            args += ["-ramdisk", magiskRamdiskURL(api: inst.api).path]
        case .playStore: break
        }
        args += extra

        let log = logsURL.appendingPathComponent("AndroidManager-\(inst.id).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { notice = "Cannot write \(log.path)"; return false }
        let p = Process()
        p.executableURL = emulatorURL
        p.arguments = args
        p.environment = toolEnvironment()
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            notice = "Starting \(inst.displayName)…"
            if let i = instances.firstIndex(where: { $0.id == inst.id }) { instances[i].running = true }
            return true
        } catch { notice = "Could not start \(inst.displayName): \(error.localizedDescription)"; return false }
    }

    func stop(_ inst: Instance) {
        // SIGTERM lets the emulator save its quick-boot snapshot and exit.
        guard let pid = inst.pid else { return }
        kill(pid, SIGTERM)
        notice = "Closing \(inst.displayName)…"
    }

    // MARK: Delete / clone / settings

    func delete(_ inst: Instance) {
        guard !inst.running else { notice = "Close \(inst.displayName) first."; return }
        let fm = FileManager.default
        try? fm.removeItem(at: inst.dir)
        try? fm.removeItem(at: avdRootURL.appendingPathComponent("\(inst.id).ini"))
        diskCache[inst.id] = nil
        notice = "Deleted \(inst.displayName)."
        reload()
    }

    private func uniqueID(from base: String) -> String {
        let existing = Set(instances.map(\.id))
        var n = 2
        var candidate = sanitizedID(base)
        while existing.contains(candidate) { candidate = "\(sanitizedID(base))_\(n)"; n += 1 }
        return candidate
    }

    /// A clone is a full independent device, so the same Android version can run
    /// several times at once. The copy is an APFS clone (`cp -c`): instant, and
    /// it only costs disk for what each copy later changes.
    func clone(_ inst: Instance, count: Int) async {
        for k in 1...max(1, count) {
            let newID = uniqueID(from: inst.id)
            let newDir = avdRootURL.appendingPathComponent("\(newID).avd")
            let r = await runTool(URL(fileURLWithPath: "/bin/cp"), ["-c", "-R", inst.dir.path, newDir.path])
            guard r.status == 0 else { notice = "Clone failed: \(r.output)"; return }
            let fm = FileManager.default
            // Locks and quick-boot state belong to the original; a copy must not
            // inherit either. Its first start is a cold boot.
            if let items = try? fm.contentsOfDirectory(at: newDir, includingPropertiesForKeys: nil) {
                for u in items where u.lastPathComponent.hasSuffix(".lock")
                    || u.lastPathComponent == "snapshots" || u.lastPathComponent == "hardware-qemu.ini"
                    || u.lastPathComponent == "multiinstance.lock" { try? fm.removeItem(at: u) }
            }
            let name = "\(inst.displayName) #\(k + (instances.filter { $0.displayName.hasPrefix(inst.displayName + " #") }.count))"
            try? editIni(newDir.appendingPathComponent("config.ini"),
                         set: ["AvdId": newID, "avd.ini.displayname": name])
            let ini = """
                avd.ini.encoding=UTF-8
                path=\(newDir.path)
                path.rel=avd/\(newID).avd
                target=android-\(inst.api)

                """
            try? ini.write(to: avdRootURL.appendingPathComponent("\(newID).ini"), atomically: true, encoding: .utf8)
            reload()
        }
        notice = "Cloned \(inst.displayName) ×\(count)."
    }

    func apply(_ inst: Instance, name: String, ram: Int, cores: Int, resolution: Resolution) {
        guard !inst.running else { notice = "Close \(inst.displayName) to change its settings."; return }
        do {
            // A device skin pins the window to its own size, so drop it when the
            // resolution changes and let the framebuffer set the window.
            try editIni(inst.dir.appendingPathComponent("config.ini"),
                        set: ["avd.ini.displayname": name,
                              "hw.ramSize": String(ram), "hw.cpu.ncore": String(cores),
                              "hw.lcd.width": String(resolution.width),
                              "hw.lcd.height": String(resolution.height),
                              "hw.lcd.density": String(resolution.density),
                              "showDeviceFrame": "no"],
                        remove: ["skin.name", "skin.path"])
            notice = "Saved settings for \(name)."
        } catch { notice = "Could not save: \(error.localizedDescription)" }
        reload()
    }

    // MARK: New instance (with download when the image is missing)

    private func log(_ s: String) { progress.append(s); if progress.count > 400 { progress.removeFirst(100) } }

    private func adbURL() -> URL { sdkURL.appendingPathComponent("platform-tools/adb") }

    /// The adb serial of the running emulator that is AVD `id`, once it has booted.
    private func waitForBoot(_ id: String, timeout: TimeInterval = 360) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(4))
            let listing = await runTool(adbURL(), ["devices"]).output
            // With the Magisk ramdisk, adbd restarts early in boot and the host's
            // adb server is left holding a dead "offline" connection to a device
            // that is in fact running. Reconnecting is what brings it back.
            if listing.contains("\toffline") { _ = await runTool(adbURL(), ["reconnect", "offline"]) }
            let devs = listing.split(separator: "\n").dropFirst()
                .compactMap { $0.contains("\tdevice") ? String($0.split(separator: "\t")[0]) : nil }
            for s in devs where s.hasPrefix("emulator-") {
                // The reply is "<name>\r\nOK\r\n". Swift treats "\r\n" as ONE character,
                // so splitting on "\n" never splits it and the name never matched.
                let name = await runTool(adbURL(), ["-s", s, "emu", "avd", "name"]).output
                    .split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard name == id else { continue }
                let done = await runTool(adbURL(), ["-s", s, "shell", "getprop", "sys.boot_completed"]).output
                if done.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return s }
            }
        }
        return nil
    }

    private func runningPID(_ id: String) async -> Int32? {
        let out = await runTool(URL(fileURLWithPath: "/bin/ps"), ["-Ao", "pid=,command="]).output
        for line in out.split(separator: "\n") where line.contains("qemu-system-aarch64") {
            let t = line.split(separator: " ", omittingEmptySubsequences: true)
            if let i = t.firstIndex(of: "-avd"), i + 1 < t.count, t[i + 1] == id, let pid = Int32(t[0]) { return pid }
        }
        return nil
    }

    private func waitStopped(_ id: String, timeout: TimeInterval = 90) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await runningPID(id) == nil { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private func stopAndWait(_ id: String) async {
        if let pid = await runningPID(id) { kill(pid, SIGTERM) }
        if !(await waitStopped(id)), let pid = await runningPID(id) { kill(pid, SIGKILL); _ = await waitStopped(id, timeout: 15) }
        reload()
    }

    /// rootAVD writes next to itself, and a signed app bundle must stay untouched,
    /// so it runs from a working copy.
    private func rootAVDWorkdir() -> URL? {
        let fm = FileManager.default
        let work = homeURL.appendingPathComponent("Library/Application Support/AndroidManager/rootAVD")
        if fm.fileExists(atPath: work.appendingPathComponent("rootAVD.sh").path) { return work }
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("rootAVD"),
              fm.fileExists(atPath: res.appendingPathComponent("rootAVD.sh").path) else { return nil }
        try? fm.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? fm.copyItem(at: res, to: work)) != nil ? work : nil
    }

    /// Gives a new Play Store device root. The root boot image is made once per
    /// Android version; after that, each device only needs the Magisk app inside.
    private func makeRooted(id: String, api: Int) async -> Bool {
        let fm = FileManager.default
        let imgDir = imageDir(api: api, tag: Kind.playStore.tag)
        let plain = imgDir.appendingPathComponent("ramdisk.img")
        let backup = imgDir.appendingPathComponent("ramdisk.img.backup")
        let dir = avdRootURL.appendingPathComponent("\(id).avd")
        guard let work = rootAVDWorkdir() else { log("rootAVD files are missing from the app."); return false }
        reload()
        guard let inst = instances.first(where: { $0.id == id }) else { return false }

        var createdRamdisk = false
        if !magiskReady(api: api) {
            log("First root for Android \(versionName(api)): patching its boot image with Magisk (about 2–3 minutes).")
            log("Only Android 12 has been verified; the result is checked at the end.")
            let orig = imgDir.appendingPathComponent("ramdisk.img.orig-backup")
            if !fm.fileExists(atPath: orig.path) { try? fm.copyItem(at: plain, to: orig) }

            log("Booting the new device once…")
            guard launch(inst, extra: ["-no-snapshot"]), let serial = await waitForBoot(id) else {
                log("The device did not boot."); await stopAndWait(id); return false
            }
            log("Running rootAVD on \(serial)…")
            let r = await runTool(URL(fileURLWithPath: "/bin/bash"),
                                  ["rootAVD.sh", "system-images/android-\(api)/\(Kind.playStore.tag)/arm64-v8a/ramdisk.img"],
                                  stdin: "\n\n\n", cwd: work, env: ["ANDROID_SERIAL": serial]) { line in
                Task { @MainActor in self.log(line) }
            }
            log("rootAVD finished (exit \(r.status)). Waiting for the device to shut down…")
            await stopAndWait(id)

            let patchedSize = (try? fm.attributesOfItem(atPath: plain.path)[.size] as? Int) ?? 0
            let originalSize = (try? fm.attributesOfItem(atPath: backup.path)[.size] as? Int) ?? 0
            guard r.status == 0, originalSize > 0, patchedSize != originalSize else {
                log("rootAVD did not produce a patched boot image."); return false
            }
            // Keep root out of the shared image: patched one gets its own name and
            // the untouched ramdisk goes back.
            do {
                try? fm.removeItem(at: magiskRamdiskURL(api: api))
                try fm.moveItem(at: plain, to: magiskRamdiskURL(api: api))
                try fm.copyItem(at: backup, to: plain)
            } catch { log("Could not arrange the boot images: \(error)"); return false }
            createdRamdisk = true
            log("Root boot image saved (\(patchedSize) bytes).")
        } else {
            log("The root boot image for Android \(versionName(api)) already exists.")
        }

        fm.createFile(atPath: rootFlagURL(dir).path, contents: Data())
        reload()
        guard let rooted = instances.first(where: { $0.id == id }), rooted.kind == .playStoreRoot else { return false }

        // Boot with the root image and finish Magisk's own setup. Verified by
        // hand on a fresh device: the app needs its "additional setup" (one
        // reboot), and `adb shell` is refused until its Superuser entry is on.
        log("Booting with root to set up Magisk…")
        guard launch(rooted, extra: ["-no-snapshot"]), var serial = await waitForBoot(id) else {
            log("The rooted device did not boot."); await stopAndWait(id); return false
        }
        let have = await runTool(adbURL(), ["-s", serial, "shell", "pm", "list", "packages", "com.topjohnwu.magisk"]).output
        if !have.contains("com.topjohnwu.magisk") {
            log("Installing the Magisk app…")
            _ = await runTool(adbURL(), ["-s", serial, "install", "-r", work.appendingPathComponent("Apps/Magisk.apk").path], timeout: 120)
        }

        func openMagisk() async {
            _ = await runTool(adbURL(), ["-s", serial, "shell", "am", "start", "-n", "com.topjohnwu.magisk/.ui.MainActivity"])
        }
        func suAnswer() async -> String {
            await runTool(adbURL(), ["-s", serial, "shell", "su", "-c", "id"], timeout: 15).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        await openMagisk()
        if await tap(serial, text: "OK", attempts: 8) {
            log("Magisk asked for additional setup; accepted. The device is rebooting…")
            try? await Task.sleep(for: .seconds(15))
            guard let again = await waitForBoot(id) else { log("It did not come back after the setup reboot."); await stopAndWait(id); return false }
            serial = again
            try? await Task.sleep(for: .seconds(8))
        }

        // The first `su` from adb is refused, and that is what makes Magisk list
        // the Shell entry — switched off. Turn it on.
        var answer = await suAnswer()
        if !answer.contains("uid=0") {
            log("Allowing the adb shell in Magisk's Superuser list…")
            await openMagisk()
            _ = await tap(serial, text: "Superuser", attempts: 6, lowest: true)
            _ = await tapSwitch(serial, attempts: 6)
            try? await Task.sleep(for: .seconds(2))
            answer = await suAnswer()
        }
        let ok = answer.contains("uid=0")
        log(ok ? "Root check passed: \(answer)" : "Root check FAILED. su said: \(answer.isEmpty ? "(nothing)" : answer)")
        await stopAndWait(id)
        if !ok {
            // Do not leave a device labelled "Root" that is not, nor a boot image
            // that does not work for this Android version.
            try? fm.removeItem(at: rootFlagURL(dir))
            if createdRamdisk { try? fm.removeItem(at: magiskRamdiskURL(api: api)) }
            log("Root did not work on Android \(versionName(api)). The device was kept as a plain Play Store device"
                + (createdRamdisk ? " and the unusable root image was removed." : "."))
            log("For root on this version, create a device of type Root instead.")
            reload()
        }
        return ok
    }

    // MARK: Driving the guest's screen (for Magisk's own dialogs)

    private struct UINode { let text: String; let checkable: Bool; let cx: Int; let cy: Int }

    private func uiNodes(_ serial: String) async -> [UINode] {
        _ = await runTool(adbURL(), ["-s", serial, "shell", "uiautomator", "dump", "/sdcard/ui.xml"], timeout: 25)
        let xml = await runTool(adbURL(), ["-s", serial, "shell", "cat", "/sdcard/ui.xml"]).output
        guard let node = try? NSRegularExpression(pattern: "<node[^>]*>"),
              let text = try? NSRegularExpression(pattern: "text=\"([^\"]*)\""),
              let chk = try? NSRegularExpression(pattern: "checkable=\"(true|false)\""),
              let bnd = try? NSRegularExpression(pattern: "bounds=\"\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]\"") else { return [] }
        let ns = xml as NSString
        return node.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let n = ns.substring(with: m.range) as NSString
            let full = NSRange(location: 0, length: n.length)
            guard let b = bnd.firstMatch(in: n as String, range: full) else { return nil }
            func g(_ r: NSTextCheckingResult, _ i: Int) -> String { n.substring(with: r.range(at: i)) }
            let nums = (1...4).compactMap { Int(g(b, $0)) }
            guard nums.count == 4 else { return nil }
            let t = text.firstMatch(in: n as String, range: full).map { g($0, 1) } ?? ""
            let c = chk.firstMatch(in: n as String, range: full).map { g($0, 1) == "true" } ?? false
            return UINode(text: t, checkable: c, cx: (nums[0] + nums[2]) / 2, cy: (nums[1] + nums[3]) / 2)
        }
    }

    /// Taps the node whose text is exactly `text`. `lowest` picks the bottom-most
    /// match, which is the tab bar rather than a screen title of the same name.
    private func tap(_ serial: String, text: String, attempts: Int, lowest: Bool = false) async -> Bool {
        for _ in 0..<attempts {
            let hits = await uiNodes(serial).filter { $0.text == text }
            if let hit = lowest ? hits.max(by: { $0.cy < $1.cy }) : hits.first {
                _ = await runTool(adbURL(), ["-s", serial, "shell", "input", "tap", "\(hit.cx)", "\(hit.cy)"])
                try? await Task.sleep(for: .seconds(2))
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private func tapSwitch(_ serial: String, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if let sw = await uiNodes(serial).first(where: { $0.checkable }) {
                _ = await runTool(adbURL(), ["-s", serial, "shell", "input", "tap", "\(sw.cx)", "\(sw.cy)"])
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    func create(version: AndroidVersion, kind: Kind, name: String, ram: Int, cores: Int, resolution: Resolution) async {
        jobTitle = "New \(version.title) · \(kind.rawValue)"
        progress = []; jobRunning = true; jobFailed = false
        defer { jobRunning = false }

        let pkg = "system-images;android-\(version.api);\(kind.tag);arm64-v8a"
        if !imageInstalled(api: version.api, kind: kind) {
            log("Downloading \(pkg) (about 1.5–2 GB). This happens once per version.")
            _ = await runTool(sdkManagerURL, ["--sdk_root=\(sdkURL.path)", "--licenses"], stdin: String(repeating: "y\n", count: 30))
            let r = await runTool(sdkManagerURL, ["--sdk_root=\(sdkURL.path)", pkg]) { line in
                Task { @MainActor in self.log(line) }
            }
            guard r.status == 0, imageInstalled(api: version.api, kind: kind) else {
                log("Download failed."); jobFailed = true; return
            }
        } else { log("Image already installed.") }

        let id = uniqueID(from: name.isEmpty ? "Android\(version.name)" : name)
        log("Creating device \(id)…")
        let r = await runTool(avdManagerURL, ["create", "avd", "-n", id, "-k", pkg, "-d", "pixel_6", "--force"], stdin: "no\n")
        guard r.status == 0 else { log(r.output); jobFailed = true; return }

        let dir = avdRootURL.appendingPathComponent("\(id).avd")
        do {
            try editIni(dir.appendingPathComponent("config.ini"),
                        set: ["avd.ini.displayname": name.isEmpty ? id : name,
                              "hw.ramSize": String(ram), "hw.cpu.ncore": String(cores),
                              "hw.keyboard": "yes", "hw.gpu.enabled": "yes",
                              "hw.lcd.width": String(resolution.width),
                              "hw.lcd.height": String(resolution.height),
                              "hw.lcd.density": String(resolution.density),
                              "showDeviceFrame": "no"],
                        remove: ["skin.name", "skin.path"])
        } catch { log("Could not write settings: \(error)"); jobFailed = true; return }

        if kind == .playStoreRoot, !(await makeRooted(id: id, api: version.api)) { jobFailed = true; reload(); return }
        log("Done.")
        reload()
    }
}
