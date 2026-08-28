import AppKit
import MultiemuSupport
import MultiemuConfiguration
import MultiemuImages
import MultiemuViewModels
import SwiftUI
import UniformTypeIdentifiers

/// The Multiemu application.
///
/// All branding, layout and artwork here is original to this project. Other
/// desktop Android emulators were studied only as functional references; no
/// third-party source, imagery, icons or trademarks are used.
@main
struct MultiemuApp: App {

    @State private var model = AppModel(
        deviceRoot: MultiemuApp.overrideRoot(for: "--device-root")
            ?? MultiemuApp.defaultDeviceRoot,
        imageRoot: MultiemuApp.overrideRoot(for: "--image-root")
            ?? MultiemuApp.defaultImageRoot
    )

    /// Alternative store locations, for automated checks and for keeping test
    /// devices out of the user's real library.
    static func overrideRoot(for flag: String) -> URL? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }

    /// Pins the interface to one appearance so both themes can be checked
    /// without changing a system setting. Absent, the app follows the system.
    static func applyAppearanceOverride() {
        guard let index = CommandLine.arguments.firstIndex(of: "--appearance"),
              index + 1 < CommandLine.arguments.count else { return }
        switch CommandLine.arguments[index + 1] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    static let defaultDeviceRoot = VirtualDeviceStore.defaultRoot()
    static let defaultImageRoot = ImageStore.defaultRoot()

    /// When set, the application captures its own window and quits. Used to
    /// verify the interface in an automated run.
    private static var capturePath: URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--capture-window"),
              index + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }

    var body: some Scene {
        Window("Multiemu", id: "main") {
            MainView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    Self.applyAppearanceOverride()
                    if CommandLine.arguments.contains("--open-new-device") {
                        model.isCreatingDevice = true
                    }
                    // Starts the first device without a click, so a boot can be
                    // verified from a script. The interface is the only place
                    // some bugs appear: the missing console ports were invisible
                    // to every CLI because the CLIs passed the ports by hand.
                    if CommandLine.arguments.contains("--start-device") {
                        Task {
                            // The activity log lives in the window. A headless
                            // run has to be told, or a failed start looks
                            // exactly like a start that has not happened yet.
                            func report(_ text: String) {
                                FileHandle.standardError.write(Data("[start-device] \(text)\n".utf8))
                            }
                            guard let device = model.devices.first else {
                                report("no devices in the store"); return
                            }
                            model.selectedDeviceID = device.id
                            report("starting \(device.name)…")
                            await device.start()

                            // With --capture-window, wait until the guest is
                            // actually up before shooting: a screenshot taken
                            // on a timer catches a black screen and proves
                            // nothing.
                            let shot = Self.capturePath
                            var captured = false
                            var seen = 0
                            for _ in 0..<40 {
                                if let shot, !captured, device.latestFrame != nil,
                                   device.statusText.contains("Running") {
                                    try? await Task.sleep(for: .seconds(20))

                                    // Swipe the keyguard away through the real
                                    // input path, so the screenshot shows the
                                    // launcher AND the swipe proves input
                                    // actually reaches the guest.
                                    if let input = device.inputClient(),
                                       let frame = device.latestFrame {
                                        let width = Double(frame.width), height = Double(frame.height)
                                        let x = width / 2
                                        do {
                                            try await input.touch(.begin, x: x, y: height * 0.8)
                                            for step in stride(from: 0.8, through: 0.2, by: -0.05) {
                                                try await input.touch(.update, x: x, y: height * step)
                                                try? await Task.sleep(for: .milliseconds(16))
                                            }
                                            try await input.touch(.end, x: x, y: height * 0.2)
                                            report("swiped up through the input path")
                                        } catch {
                                            report("swipe failed: \(error)")
                                        }
                                        try? await Task.sleep(for: .seconds(6))
                                    }

                                    _ = device.captureScreenshot(to: shot.deletingLastPathComponent())
                                    WindowCapture.captureFrontmostWindow(to: shot)
                                    report("captured \(shot.path)")
                                    captured = true
                                }
                                for entry in device.activity.dropFirst(seen) {
                                    report("\(entry.kind.rawValue): \(entry.text)")
                                }
                                seen = device.activity.count
                                if let error = device.lastError { report("error: \(error)") }
                                if let frame = device.latestFrame {
                                    report("frame: \(frame.width)x\(frame.height)  presented=\(device.framesPresented)")
                                }
                                report("state: \(device.statusText)")
                                try? await Task.sleep(for: .seconds(3))
                            }
                        }
                    }
                    if let path = Self.capturePath,
                       !CommandLine.arguments.contains("--start-device") {
                        WindowCapture.scheduleCapture(to: path)
                    }
                    if let path = Self.overrideRoot(for: "--dump-accessibility") {
                        AccessibilityDump.scheduleDump(to: path)
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Device…") { model.isCreatingDevice = true }
                    .keyboardShortcut("n")
                    .disabled(!model.isOperational)
            }
            CommandMenu("Device") {
                Button("Start") { Task { await model.selectedDevice?.start() } }
                    .keyboardShortcut("r")
                    .disabled(model.selectedDevice?.canStart != true)
                Button("Shut Down") { Task { await model.selectedDevice?.stop() } }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(model.selectedDevice?.canStop != true)
                Divider()
                Button("Take Screenshot") { model.captureScreenshotOfSelection() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.selectedDevice?.latestFrame == nil)
                Divider()
                Button("Install APK…") { chooseAndInstallPackage(into: model) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    // Disabled rather than hidden, and disabled for a reason
                    // the user can act on: a stopped device has no adbd, and a
                    // device with no ADB forward has nowhere to send it.
                    .disabled(!model.canInstallPackage)
            }
        }
    }
}

/// Asks for an APK and hands it to the selected device.
///
/// `NSOpenPanel` lives here rather than in `AppModel` because a model that
/// opens a panel cannot be tested without one. The model takes a URL.
@MainActor
private func chooseAndInstallPackage(into model: AppModel) {
    let panel = NSOpenPanel()
    panel.title = "Install APK"
    panel.prompt = "Install"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await model.installPackageIntoSelection(from: url) }
}
