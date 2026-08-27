import MultiemuSupport
import MultiemuViewModels
import SwiftUI

struct DeviceListView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedDeviceID) {
            Section("Virtual devices") {
                ForEach(model.devices) { device in
                    DeviceRow(device: device).tag(device.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.isCreatingDevice = true
                } label: {
                    Label("New Device", systemImage: "plus")
                }
                .disabled(!model.isOperational)

                Spacer()

                if let device = model.selectedDevice {
                    Menu {
                        Button("Factory Reset…", role: .destructive) {
                            Task { await device.factoryReset() }
                        }
                        .disabled(device.isRunning)
                        Button("Delete Device…", role: .destructive) {
                            Task { await model.deleteDevice(device) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(10)
            .background(.bar)
        }
    }
}

struct DeviceRow: View {
    let device: DeviceModel

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: device.statusText, running: device.isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).lineLimit(1)
                Text(device.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A small state indicator. Colour alone never carries the meaning — the row
/// always shows the state in words too, so the interface stays readable for
/// anyone who cannot distinguish the colours.
struct StatusDot: View {
    let state: String
    let running: Bool

    private var colour: Color {
        if state.hasPrefix("Failed") { return .red }
        if state == "Running" { return .green }
        if running { return .orange }
        return .secondary
    }

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
