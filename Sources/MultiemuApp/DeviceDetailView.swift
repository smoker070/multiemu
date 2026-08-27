import MultiemuGraphics
import MultiemuSupport
import MultiemuViewModels
import MultiemuConfiguration
import SwiftUI

struct DeviceDetailView: View {
    @Bindable var device: DeviceModel
    @Bindable var model: AppModel
    @State private var showsActivity = true
    @State private var showsSettings = CommandLine.arguments.contains("--open-settings")
    @State private var snapshotName = ""
    @State private var isNamingSnapshot = false

    var body: some View {
        VSplitView {
            GuestDisplayArea(device: device)
                .frame(minHeight: 260)

            if showsActivity {
                ActivityLogView(device: device)
                    .frame(minHeight: 120, idealHeight: 190)
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle(device.name)
        .navigationSubtitle(device.statusText)
        .sheet(isPresented: $showsSettings) {
            DeviceSettingsSheet(device: device, model: model)
        }
        .alert("Name this snapshot", isPresented: $isNamingSnapshot) {
            TextField("Snapshot name", text: $snapshotName)
            Button("Capture") {
                let tag = snapshotName.isEmpty ? "snapshot" : snapshotName
                Task { await device.captureSnapshot(named: tag) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { device.canStart ? await device.start() : await device.stop() }
            } label: {
                Label(device.canStart ? "Start" : "Shut Down",
                      systemImage: device.canStart ? "play.fill" : "stop.fill")
            }
            .help(device.canStart ? "Start this device" : "Ask the guest to shut down")

            Button { Task { await device.restart() } } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .disabled(!device.isRunning)

            Divider()

            Button {
                snapshotName = ""
                isNamingSnapshot = true
            } label: {
                Label("Snapshot", systemImage: "camera.aperture")
            }
            .disabled(!device.canSnapshot)
            .help("Capture the device's memory and disk state")

            Menu {
                if device.snapshots.isEmpty {
                    Text("No snapshots yet")
                } else {
                    ForEach(device.snapshots, id: \.tag) { handle in
                        Button(handle.tag) { Task { await device.restoreSnapshot(handle) } }
                    }
                }
            } label: {
                Label("Restore", systemImage: "clock.arrow.circlepath")
            }
            .disabled(!device.isRunning)
            .task(id: device.state.displayName) { await device.refreshSnapshots() }

            Button { model.captureScreenshotOfSelection() } label: {
                Label("Screenshot", systemImage: "square.and.arrow.down")
            }
            .disabled(device.latestFrame == nil)

            Button {
                if device.isRecording {
                    Task { await device.stopRecording() }
                } else {
                    device.startRecording()
                }
            } label: {
                // The label changes with the state, not just the icon: "stop"
                // and "record" must be tellable apart without relying on colour.
                Label(device.isRecording ? "Stop Recording" : "Record",
                      systemImage: device.isRecording ? "stop.circle" : "record.circle")
            }
            .disabled(device.latestFrame == nil)

            Menu {
                Button {
                    Task { await device.rotateDisplay() }
                } label: {
                    Label("Rotate", systemImage: "rotate.right")
                }
                Divider()
                ForEach(DisplayProfile.allPresets, id: \.name) { preset in
                    Button {
                        Task { await device.applyDisplayProfile(preset.profile) }
                    } label: {
                        Label(
                            preset.name,
                            systemImage: preset.profile == device.profile.display ? "checkmark" : "")
                    }
                }
                Divider()
                Text("\(device.profile.display.densityDPI) dpi")
            } label: {
                Label("Display", systemImage: "rectangle.on.rectangle")
            }
            .disabled(!device.isRunning)

            Menu {
                // A check mark rather than colour alone, so the active mapping
                // is legible without relying on hue.
                ForEach(device.profile.effectiveInputProfiles) { mapping in
                    Button {
                        device.selectInputProfile(mapping.id)
                    } label: {
                        Label(
                            mapping.name,
                            systemImage: mapping.id == device.profile.activeInputProfile?.id
                                ? "checkmark" : "")
                    }
                }
                Divider()
                Text("\(device.profile.activeInputProfile?.bindings.count ?? 0) bindings")
            } label: {
                Label("Input mapping", systemImage: "gamecontroller")
            }

            Divider()

            Picker("Scaling", selection: $device.scaling) {
                Text("Fit").tag(GuestDisplayScaling.aspectFit)
                Text("Fill").tag(GuestDisplayScaling.aspectFill)
                Text("Stretch").tag(GuestDisplayScaling.stretch)
                Text("1:1").tag(GuestDisplayScaling.integerScale)
            }
            .pickerStyle(.menu)
            .fixedSize()

            Toggle(isOn: $showsActivity) {
                Label("Activity", systemImage: "list.bullet.rectangle")
            }

            Button { showsSettings = true } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .disabled(device.isRunning)
            .help(device.isRunning ? "Stop the device to change its settings" : "Configure this device")
        }
    }
}

/// The guest display, or an explanation of why there is nothing to show.
struct GuestDisplayArea: View {
    @Bindable var device: DeviceModel
    /// Set while an APK is over the display, so the drop has a target the user
    /// can see before letting go.
    @State private var isTargetedForDrop = false

    var body: some View {
        ZStack {
            Color.black
            if device.latestFrame != nil {
                GuestDisplayHost(device: device)
                    // Give each device its own view state; without this the
                    // renderer and its coordinator are reused across a
                    // selection change.
                    .id(device.id)
            } else {
                VStack(spacing: 10) {
                    if device.isRunning {
                        ProgressView()
                        Text(device.statusText).foregroundStyle(.secondary)
                    } else {
                        BrandMark(size: 64).opacity(0.4)
                        Text("This device is not running")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // The guest surface is always black, whatever the app appearance, so the
        // labels drawn on it must resolve their semantic colours against a dark
        // background. Without this they turn dark-on-black in light appearance.
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottomTrailing) {
            if device.latestFrame != nil {
                Text("\(device.profile.display.widthInPixels) × \(device.profile.display.heightInPixels)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
            }
        }
        // Dropping an APK on the screen installs it. The brief calls
        // drag-and-drop a security boundary, so the path a drop takes is the
        // same one the menu item takes: the file is validated as an APK before
        // any of it is sent, and the guest is never handed a host path.
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            guard device.canInstallPackage, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await device.installPackage(at: url) }
            }
            return true
        }
        .overlay {
            if isTargetedForDrop && device.canInstallPackage {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .overlay {
                        Text("Drop an APK to install")
                            .font(.headline)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
    }
}
