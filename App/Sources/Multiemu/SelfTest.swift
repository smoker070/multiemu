import Foundation

/// `Android --selftest <source-avd-id>`: drives the real InstanceStore through
/// clone → start both at once → verify two live devices → stop → delete the clone.
/// Output goes to stdout; the exit code is 0 only if every check passed.
@MainActor
func runSelfTest(source: String) async -> Int32 {
    let store = InstanceStore()
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    func adb(_ args: [String]) async -> String {
        await runTool(sdkURL.appendingPathComponent("platform-tools/adb"), args).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard let original = store.instances.first(where: { $0.id == source }) else { print("no such instance \(source)"); return 2 }
    check(!original.running, "source \(source) is not running at the start")
    let before = Set(store.instances.map(\.id))

    await store.clone(original, count: 1)
    let added = store.instances.filter { !before.contains($0.id) }
    check(added.count == 1, "clone created exactly one new instance")
    guard let copy = added.first else { return 1 }
    print("      clone id: \(copy.id)  name: \(copy.displayName)")
    check(copy.api == original.api && copy.kind == original.kind, "clone has the same Android version and type")
    check(FileManager.default.fileExists(atPath: avdRootURL.appendingPathComponent("\(copy.id).ini").path), "clone has its .ini")
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: copy.dir.path)) ?? [])
        .filter { $0.hasSuffix(".lock") || $0 == "snapshots" }
    check(leftovers.isEmpty, "clone carries no locks or snapshots (\(leftovers))")

    store.start(original); store.start(copy)
    print("      starting both, waiting for two booted devices…")
    var serials: [String] = []
    for _ in 0..<90 {
        try? await Task.sleep(for: .seconds(4))
        let devs = await adb(["devices"]).split(separator: "\n").dropFirst()
            .compactMap { $0.contains("\tdevice") ? String($0.split(separator: "\t")[0]) : nil }
        var ready: [String] = []
        for s in devs where await adb(["-s", s, "shell", "getprop", "sys.boot_completed"]) == "1" { ready.append(s) }
        if ready.count >= 2 { serials = ready; break }
    }
    check(serials.count == 2, "two devices booted at the same time \(serials)")
    store.refreshRunning(); try? await Task.sleep(for: .seconds(2))
    check(store.instances.filter(\.running).count >= 2, "the manager shows both as Running")
    for s in serials {
        let rel = await adb(["-s", s, "shell", "getprop", "ro.build.version.release"])
        let who = await adb(["-s", s, "emu", "avd", "name"]).split(separator: "\n").first.map(String.init) ?? "?"
        print("      \(s): Android \(rel)  avd=\(who)")
    }

    store.stop(original); store.stop(copy)
    for _ in 0..<30 { try? await Task.sleep(for: .seconds(2)); store.refreshRunning()
        try? await Task.sleep(for: .seconds(1))
        if store.instances.filter({ $0.id == original.id || $0.id == copy.id }).allSatisfy({ !$0.running }) { break } }
    check(store.instances.filter({ $0.id == original.id || $0.id == copy.id }).allSatisfy { !$0.running }, "both stopped cleanly")

    if let fresh = store.instances.first(where: { $0.id == copy.id }) { store.delete(fresh) }
    check(!store.instances.contains { $0.id == copy.id }
          && !FileManager.default.fileExists(atPath: copy.dir.path), "clone deleted from disk")
    check(store.instances.contains { $0.id == original.id }, "original untouched")
    print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
    return failures == 0 ? 0 : 1
}

/// `Android --selftest-settings <source-avd-id>`: clones, applies a tablet screen,
/// 2 GB RAM and 2 cores, boots it, and asks the guest what it actually got.
@MainActor
func runSettingsSelfTest(source: String) async -> Int32 {
    let store = InstanceStore()
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    func adb(_ args: [String]) async -> String {
        await runTool(sdkURL.appendingPathComponent("platform-tools/adb"), args).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let original = store.instances.first(where: { $0.id == source }) else { print("no such instance"); return 2 }
    let before = Set(store.instances.map(\.id))
    await store.clone(original, count: 1)
    guard let copy = store.instances.first(where: { !before.contains($0.id) }) else { print("clone failed"); return 1 }

    let tablet = resolutions.first { $0.label.hasPrefix("Tablet 1280") }!
    store.apply(copy, name: "Settings test", ram: 2048, cores: 2, resolution: tablet)
    let saved = store.instances.first { $0.id == copy.id }!
    check(saved.ramMB == 2048 && saved.cores == 2 && saved.width == 800 && saved.height == 1280, "settings were written and read back")
    check(saved.displayName == "Settings test", "new name stored")
    let cfg = (try? String(contentsOf: copy.dir.appendingPathComponent("config.ini"), encoding: .utf8)) ?? ""
    check(!cfg.contains("skin.name") && !cfg.contains("skin.path"), "device skin dropped so it cannot pin the old size")

    store.start(saved)
    var serial = ""
    for _ in 0..<90 {
        try? await Task.sleep(for: .seconds(4))
        let s = await adb(["devices"]).split(separator: "\n").dropFirst().compactMap { $0.contains("\tdevice") ? String($0.split(separator: "\t")[0]) : nil }.first ?? ""
        if !s.isEmpty, await adb(["-s", s, "shell", "getprop", "sys.boot_completed"]) == "1" { serial = s; break }
    }
    check(!serial.isEmpty, "settings-test device booted (\(serial))")
    if !serial.isEmpty {
        let size = await adb(["-s", serial, "shell", "wm", "size"])
        let dens = await adb(["-s", serial, "shell", "wm", "density"])
        let mem = await adb(["-s", serial, "shell", "grep", "MemTotal", "/proc/meminfo"])
        let cpus = await adb(["-s", serial, "shell", "nproc"])
        print("      wm size: \(size) | density: \(dens) | \(mem) | nproc: \(cpus)")
        check(size.contains("800x1280"), "guest screen is 800x1280 (asked for the tablet preset)")
        check(dens.contains("240"), "guest density is 240")
        check(cpus == "2", "guest sees 2 CPU cores")
        let kb = Int(mem.split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? "") ?? 0
        check(kb > 1_500_000 && kb < 2_300_000, "guest memory is about 2 GB (\(kb) kB)")
    }
    store.stop(saved)
    for _ in 0..<30 { try? await Task.sleep(for: .seconds(3)); store.refreshRunning()
        try? await Task.sleep(for: .seconds(1))
        if store.instances.first(where: { $0.id == copy.id })?.running == false { break } }
    if let fresh = store.instances.first(where: { $0.id == copy.id }) { store.delete(fresh) }
    check(!store.instances.contains { $0.id == copy.id }, "test device removed")
    print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
    return failures == 0 ? 0 : 1
}

/// `Android --selftest-newroot <api>`: creates a "Play Store + Root" device through
/// the real New flow, then a plain Play Store device of the same version, and
/// checks that only the first can `su`.
@MainActor
func runNewRootSelfTest(api: Int) async -> Int32 {
    let store = InstanceStore()
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }
    func adb(_ args: [String], timeout: TimeInterval? = nil) async -> String {
        await runTool(sdkURL.appendingPathComponent("platform-tools/adb"), args, timeout: timeout).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let version = androidVersions.first(where: { $0.api == api }) else { return 2 }
    let phone = resolutions[0]
    print("root image ready before: \(magiskReady(api: api))")

    // 1. rooted device through the real flow
    await store.create(version: version, kind: .playStoreRoot, name: "RootTest\(api)", ram: 3072, cores: 2, resolution: phone)
    for l in store.progress where !l.hasPrefix("[") && l.count < 160 { print("   | \(l)") }
    check(!store.jobFailed, "New → Play Store + Root finished without failure")
    let rooted = store.instances.first { $0.displayName == "RootTest\(api)" }
    check(rooted?.kind == .playStoreRoot, "device is listed as Play Store + Root")
    check(magiskReady(api: api), "root boot image exists for Android \(version.name)")
    let plainRamdiskSize = (try? FileManager.default.attributesOfItem(atPath: imageDir(api: api, tag: Kind.playStore.tag).appendingPathComponent("ramdisk.img").path)[.size] as? Int) ?? 0
    let magiskSize = (try? FileManager.default.attributesOfItem(atPath: magiskRamdiskURL(api: api).path)[.size] as? Int) ?? 0
    check(plainRamdiskSize > 0 && plainRamdiskSize < magiskSize, "shared ramdisk.img stays the untouched one (\(plainRamdiskSize) < \(magiskSize))")

    // 2. a plain Play Store device of the same version must NOT be rooted
    await store.create(version: version, kind: .playStore, name: "PlainTest\(api)", ram: 3072, cores: 2, resolution: phone)
    let plain = store.instances.first { $0.displayName == "PlainTest\(api)" }
    check(plain?.kind == .playStore, "plain device is listed as Play Store")
    if let plain {
        store.launch(plain, extra: ["-no-snapshot"])
        var serial = ""
        for _ in 0..<90 {
            try? await Task.sleep(for: .seconds(4))
            let devs = await adb(["devices"]).split(separator: "\n").dropFirst().compactMap { $0.contains("\tdevice") ? String($0.split(separator: "\t")[0]) : nil }
            for s in devs where (await adb(["-s", s, "emu", "avd", "name"])).hasPrefix(plain.id) {
                if await adb(["-s", s, "shell", "getprop", "sys.boot_completed"]) == "1" { serial = s }
            }
            if !serial.isEmpty { break }
        }
        check(!serial.isEmpty, "plain device booted")
        if !serial.isEmpty {
            let su = await adb(["-s", serial, "shell", "su -c id 2>&1"], timeout: 20)
            print("      plain su: \(su)")
            check(!su.contains("uid=0"), "plain Play Store device has NO root")
        }
        if let pid = await Task { store.instances.first { $0.id == plain.id }?.pid }.value { kill(pid, SIGTERM) }
        for _ in 0..<30 { store.refreshRunning(); try? await Task.sleep(for: .seconds(3))
            if store.instances.first(where: { $0.id == plain.id })?.running == false { break } }
    }

    for d in [rooted, plain].compactMap({ $0 }) { if let f = store.instances.first(where: { $0.id == d.id }) { store.delete(f) } }
    check(!store.instances.contains { $0.displayName.hasSuffix("Test\(api)") }, "test devices removed")
    print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
    return failures == 0 ? 0 : 1
}
