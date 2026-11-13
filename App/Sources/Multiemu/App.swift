import SwiftUI

@main
struct MultiemuApp: App {
    @StateObject private var store = InstanceStore()
    @StateObject private var updater = Updater()
    @StateObject private var setup = SetupModel()

    init() {
        if CommandLine.arguments.contains("--selftest-update") {
            Task { @MainActor in
                let u = Updater()
                await u.check()
                print("current \(appVersion), available \(u.available?.version ?? "none")")
                if u.available == nil { fflush(stdout); exit(1) }
                await u.install()   // quits on success
                print(u.status); fflush(stdout); exit(1)
            }
        }
        if CommandLine.arguments.contains("--selftest-setup") {
            Task { @MainActor in
                let m = SetupModel()
                print("before: \(m.state)")
                await m.install()
                m.lines.forEach { print($0) }
                print("after: \(sdkState()) java=\(findJavaHome() ?? "none")")
                fflush(stdout); exit(sdkState() == .ready ? 0 : 1)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-newroot"), i + 1 < CommandLine.arguments.count,
           let api = Int(CommandLine.arguments[i + 1]) {
            Task { @MainActor in
                let code = await runNewRootSelfTest(api: api)
                fflush(stdout); exit(code)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-settings"), i + 1 < CommandLine.arguments.count {
            let source = CommandLine.arguments[i + 1]
            Task { @MainActor in
                let code = await runSettingsSelfTest(source: source)
                fflush(stdout); exit(code)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            let source = CommandLine.arguments[i + 1]
            Task { @MainActor in
                let code = await runSelfTest(source: source)
                fflush(stdout); exit(code)
            }
        }
    }
    var body: some Scene {
        Window("Multiemu", id: "main") {
            ManagerView()
                .environmentObject(store)
                .environmentObject(updater)
                .environmentObject(setup)
                .task { await updater.check() }
                .frame(minWidth: 1080, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 640)
    }
}
