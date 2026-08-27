import MultiemuViewModels
import SwiftUI

/// The device's activity: state changes, boot milestones, notices and console.
///
/// Present from the first milestone of the interface rather than added later,
/// because "what is it doing" and "why did it stop" are the two questions an
/// emulator has to answer continuously.
struct ActivityLogView: View {
    let device: DeviceModel
    @State private var filter: ActivityEntry.Kind?

    private var entries: [ActivityEntry] {
        guard let filter else { return device.activity }
        return device.activity.filter { $0.kind == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Show", selection: $filter) {
                    Text("All").tag(ActivityEntry.Kind?.none)
                    Text("State").tag(ActivityEntry.Kind?.some(.state))
                    Text("Boot").tag(ActivityEntry.Kind?.some(.boot))
                    Text("Console").tag(ActivityEntry.Kind?.some(.console))
                    Text("Problems").tag(ActivityEntry.Kind?.some(.error))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Text("\(device.framesPresented) frames")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    let text = device.activity.map(\.text).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .help("Copy the activity log")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.kind.rawValue)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(colour(for: entry.kind))
                                    .frame(width: 58, alignment: .leading)
                                Text(entry.text)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: entries.count) {
                    if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(.background)
    }

    private func colour(for kind: ActivityEntry.Kind) -> Color {
        switch kind {
        case .error: return .red
        case .state: return .accentColor
        case .boot: return .green
        case .notice: return .orange
        case .console: return .secondary
        }
    }
}
