import MultiemuSupport
import MultiemuViewModels
import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            DeviceListView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if !model.setupProblems.isEmpty {
                SetupIssuesView(problems: model.setupProblems, host: model.host)
            } else if let device = model.selectedDevice {
                DeviceDetailView(device: device, model: model)
            } else {
                EmptySelectionView(model: model)
            }
        }
        .sheet(isPresented: $model.isCreatingDevice) {
            NewDeviceSheet(model: model)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

/// Shown when the Mac or the toolchain cannot run a guest at all.
///
/// Deliberately a first-class screen rather than an error alert: the user needs
/// to know precisely what is missing and where it was looked for, which is far
/// more useful than "something failed".
struct SetupIssuesView: View {
    let problems: [String]
    let host: HostCapabilitiesSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Multiemu cannot run a virtual device yet", systemImage: "exclamationmark.triangle")
                .font(.title2.weight(.semibold))

            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 7)
                    Text(problem).textSelection(.enabled)
                }
            }

            Divider()
            Text("This Mac")
                .font(.headline)
            LabeledContent("Processor", value: host.cpuDescription)
            LabeledContent("Memory", value: host.memoryDescription)
            LabeledContent("Hardware virtualization",
                           value: host.hardwareVirtualizationAvailable ? "Available" : "Unavailable")
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct EmptySelectionView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            BrandMark(size: 76)
            Text("No virtual device selected")
                .font(.title3.weight(.medium))
            Text("Create a device to get started.")
                .foregroundStyle(.secondary)
            Button("New Virtual Device…") { model.isCreatingDevice = true }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isOperational)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Multiemu mark: two offset rounded rectangles, suggesting more than one
/// device. Drawn in code so it scales cleanly and carries no external asset.
struct BrandMark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(.tertiary)
                .frame(width: size * 0.52, height: size * 0.74)
                .offset(x: -size * 0.14, y: -size * 0.04)
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: size * 0.52, height: size * 0.74)
                .offset(x: size * 0.14, y: size * 0.04)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Multiemu")
    }
}
