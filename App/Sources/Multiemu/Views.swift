import SwiftUI
import AppKit

let accent = Color(red: 0.10, green: 0.74, blue: 0.52)

enum ActiveSheet: Identifiable {
    case new, job, setup
    case settings(Instance)
    var id: String {
        switch self {
        case .new: return "new"
        case .job: return "job"
        case .setup: return "setup"
        case .settings(let i): return "settings-\(i.id)"
        }
    }
}

struct ManagerView: View {
    @EnvironmentObject var store: InstanceStore
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var setup: SetupModel
    @State private var selection = Set<String>()
    @State private var sheet: ActiveSheet?
    @State private var pendingDelete: [Instance] = []
    @State private var cloneTarget: Instance?
    @State private var cloneCount = 2

    private var selected: [Instance] { store.instances.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            table
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Launch flags used to check the dialogs without clicking.
            let a = CommandLine.arguments
            if setup.state == .missing || a.contains("--open-setup") { sheet = .setup; return }
            if a.contains("--open-new") { sheet = .new }
            if a.contains("--open-settings"), let first = store.instances.first { sheet = .settings(first) }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .new: NewInstanceSheet(sheet: $sheet)
            case .job: JobSheet(sheet: $sheet)
            case .setup: SetupView(setup: setup) { sheet = nil; store.reload() }
            case .settings(let i): SettingsSheet(instance: i, sheet: $sheet)
            }
        }
        .confirmationDialog(
            pendingDelete.count == 1 ? "Delete “\(pendingDelete[0].displayName)”?" : "Delete \(pendingDelete.count) instances?",
            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                pendingDelete.forEach { store.delete($0) }
                selection.subtract(pendingDelete.map(\.id)); pendingDelete = []
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: { Text("The virtual device and everything inside it (apps, files, accounts) is removed. This cannot be undone.") }
        .alert("Clone “\(cloneTarget?.displayName ?? "")”", isPresented: Binding(get: { cloneTarget != nil }, set: { if !$0 { cloneTarget = nil } })) {
            Stepper("Copies: \(cloneCount)", value: $cloneCount, in: 1...8)
            Button("Clone") { if let t = cloneTarget { Task { await store.clone(t, count: cloneCount) } }; cloneTarget = nil }
            Button("Cancel", role: .cancel) { cloneTarget = nil }
        } message: { Text("Each copy is an independent device, so the same Android version can run several times at once.") }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { selected.filter { !$0.running }.forEach(store.start) } label: { Label("Start", systemImage: "play.fill") }
                .disabled(selected.allSatisfy(\.running) || selected.isEmpty)
            Button { selected.filter(\.running).forEach(store.stop) } label: { Label("Close", systemImage: "stop.fill") }
                .disabled(!selected.contains(where: \.running))
            Button { if selected.count == 1 { sheet = .settings(selected[0]) } } label: { Label("Settings", systemImage: "gearshape") }
                .disabled(selected.count != 1)
            Button { if selected.count == 1 { cloneCount = 2; cloneTarget = selected[0] } } label: { Label("Clone", systemImage: "square.on.square") }
                .disabled(selected.count != 1)
            Button(role: .destructive) { pendingDelete = selected } label: { Label("Delete", systemImage: "trash") }
                .disabled(selected.isEmpty || selected.contains(where: \.running))
            Spacer()
            Text("\(store.instances.filter(\.running).count) running")
                .foregroundStyle(.secondary).font(.callout)
        }
        .buttonStyle(.bordered).controlSize(.large)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Table

    private var table: some View {
        Table(store.instances, selection: $selection) {
            TableColumn("") { i in
                Toggle("", isOn: Binding(
                    get: { selection.contains(i.id) },
                    set: { if $0 { selection.insert(i.id) } else { selection.remove(i.id) } }
                )).labelsHidden().toggleStyle(.checkbox)
            }.width(28)
            TableColumn("#") { i in
                Text("\((store.instances.firstIndex(of: i) ?? 0) + 1)").foregroundStyle(.secondary)
            }.width(28)
            TableColumn("Name") { i in Text(i.displayName).fontWeight(.medium) }
            TableColumn("Android") { i in Text(i.androidLabel) }.width(min: 80, ideal: 90)
            TableColumn("Type") { i in
                Text(i.typeLabel)
                    .font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
                    .background((i.kind.isRooted ? Color.orange : accent).opacity(0.22), in: Capsule())
            }.width(min: 90, ideal: 130)
            TableColumn("Screen") { i in Text(i.resolutionLabel).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
            TableColumn("Disk") { i in
                Text(i.diskBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                    .foregroundStyle(.secondary)
            }.width(min: 60, ideal: 70)
            TableColumn("Status") { i in
                HStack(spacing: 5) {
                    Circle().fill(i.running ? accent : Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                    Text(i.running ? "Running" : "Power off").foregroundStyle(i.running ? accent : .secondary)
                }
            }.width(min: 90, ideal: 100)
            TableColumn("Operations") { i in
                HStack(spacing: 6) {
                    if i.running {
                        Button { store.stop(i) } label: { Label("Close", systemImage: "stop.fill").frame(width: 66) }
                    } else {
                        Button { store.start(i) } label: { Label("Start", systemImage: "play.fill").frame(width: 66) }
                            .tint(accent)
                    }
                    Button { sheet = .settings(i) } label: { Image(systemName: "gearshape") }.disabled(i.running)
                    Menu {
                        Button("Clone…") { cloneCount = 2; cloneTarget = i }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([i.dir]) }
                        Button("Open log") {
                            NSWorkspace.shared.open(logsURL.appendingPathComponent("AndroidManager-\(i.id).log"))
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = [i] }.disabled(i.running)
                    } label: { Image(systemName: "ellipsis").frame(width: 20, height: 18) }
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                }.buttonStyle(.bordered)
            }.width(min: 200, ideal: 220)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if store.instances.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.gen3").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No instances yet").font(.title3)
                    Text("Press New to create an Android device.").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(store.notice.isEmpty ? "\(selection.count) selected" : store.notice)
                .foregroundStyle(accent).font(.callout).lineLimit(1)
            Spacer()
            if let rel = updater.available {
                HStack(spacing: 8) {
                    if updater.busy { ProgressView().controlSize(.small) }
                    Text(updater.status.isEmpty ? "Multiemu \(rel.version) is available" : updater.status)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Button { Task { await updater.install() } } label: {
                        Label("Update now", systemImage: "arrow.down.circle")
                    }.buttonStyle(.bordered).tint(accent).controlSize(.large).disabled(updater.busy)
                    .help(rel.body ?? "")
                }
            }
            Button { store.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered).controlSize(.large)
            Button { sheet = setup.state == .ready ? .new : .setup } label: { Label("New", systemImage: "plus").frame(minWidth: 70) }
                .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - New instance

struct NewInstanceSheet: View {
    @EnvironmentObject var store: InstanceStore
    @Binding var sheet: ActiveSheet?
    // `--new-api 28 --new-kind root+play` open the dialog in a given state, so
    // each warning can be checked on screen without clicking.
    private static func arg(_ k: String) -> String? {
        let a = CommandLine.arguments
        return a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }
    @State private var version = androidVersions.first { $0.api == Int(NewInstanceSheet.arg("--new-api") ?? "") }
        ?? androidVersions.first { $0.api == 31 }!
    @State private var kind: Kind = {
        switch NewInstanceSheet.arg("--new-kind") {
        case "root+play": return .playStoreRoot
        case "root": return .root
        default: return .playStore
        }
    }()
    @State private var name = ""
    @State private var ram = 4096
    @State private var cores = 4
    @State private var resolution = resolutions[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Android device").font(.title2.bold())

            Text("Android version").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(androidVersions) { v in
                    let have = imageInstalled(api: v.api, kind: kind)
                    Button { version = v } label: {
                        VStack(spacing: 2) {
                            Text(v.title).fontWeight(.semibold)
                            Text(have ? "installed" : "~1.5 GB download").font(.caption2)
                                .foregroundStyle(have ? accent : .secondary)
                        }.frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(.bordered)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(version == v ? accent : .clear, lineWidth: 2))
                }
            }

            Text("Type").font(.headline)
            Picker("", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Text(kind.blurb).font(.callout).foregroundStyle(.secondary)
            if kind == .playStoreRoot {
                switch rootVerified[version.api] {
                case true?:
                    Text(magiskReady(api: version.api)
                         ? "Tested: root works on Android \(version.name). The root boot image is ready."
                         : "Tested: root works on Android \(version.name). A one-time patch runs first (about 2–3 minutes).")
                        .font(.callout).foregroundStyle(accent)
                case false?:
                    Text("Tested: the root patch does not take effect on Android \(version.name). Choose Root (no Play Store) instead.")
                        .font(.callout).foregroundStyle(.red)
                case nil:
                    Text("Not tested on Android \(version.name). A one-time patch runs first and the result is checked; if root does not work the device stays a plain Play Store device.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            Form {
                TextField("Name", text: $name, prompt: Text("Android \(version.name)"))
                Picker("Screen", selection: $resolution) { ForEach(resolutions) { Text($0.label).tag($0) } }
                Picker("Memory", selection: $ram) { ForEach(ramOptions, id: \.self) { Text("\($0 / 1024 >= 1 && $0 % 1024 == 0 ? "\($0 / 1024) GB" : "\($0) MB")").tag($0) } }
                Picker("CPU cores", selection: $cores) { ForEach(coreOptions, id: \.self) { Text("\($0)").tag($0) } }
            }.formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let n = name.isEmpty ? "Android \(version.name)" : name
                    sheet = .job
                    Task { await store.create(version: version, kind: kind, name: n, ram: ram, cores: cores, resolution: resolution) }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(accent)
            }
        }
        .padding(22).frame(width: 580)
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject var store: InstanceStore
    let instance: Instance
    @Binding var sheet: ActiveSheet?
    @State private var name = ""
    @State private var ram = 4096
    @State private var cores = 4
    @State private var resolution = resolutions[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2.bold())
            Text("\(instance.androidLabel) · \(instance.typeLabel)").foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                Picker("Screen", selection: $resolution) { ForEach(resolutions) { Text($0.label).tag($0) } }
                Picker("Memory", selection: $ram) {
                    ForEach(Array(Set(ramOptions + [instance.ramMB])).sorted(), id: \.self) {
                        Text($0 % 1024 == 0 ? "\($0 / 1024) GB" : "\($0) MB").tag($0)
                    }
                }
                Picker("CPU cores", selection: $cores) {
                    ForEach(Array(Set(coreOptions + [instance.cores])).sorted(), id: \.self) { Text("\($0)").tag($0) }
                }
            }.formStyle(.grouped)
            Text("Changes apply the next time the device starts.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { sheet = nil }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    store.apply(instance, name: name.isEmpty ? instance.displayName : name,
                                ram: ram, cores: cores, resolution: resolution)
                    sheet = nil
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(accent)
            }
        }
        .padding(22).frame(width: 500)
        .onAppear {
            name = instance.displayName; ram = instance.ramMB; cores = instance.cores
            resolution = resolutions.first { $0.width == instance.width && $0.height == instance.height }
                ?? Resolution(label: "Current \(instance.width) × \(instance.height) (\(instance.density) dpi)",
                              width: instance.width, height: instance.height, density: instance.density)
        }
    }
}

// MARK: - Progress of a long job

struct JobSheet: View {
    @EnvironmentObject var store: InstanceStore
    @Binding var sheet: ActiveSheet?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.jobTitle).font(.title3.bold())
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.progress.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(.caption, design: .monospaced)).id(i)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: store.progress.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            .padding(8).background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            .frame(height: 220)
            HStack {
                if store.jobRunning { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(.secondary) }
                else if store.jobFailed { Label("Failed", systemImage: "xmark.octagon").foregroundStyle(.red) }
                else { Label("Done", systemImage: "checkmark.circle").foregroundStyle(accent) }
                Spacer()
                Button("Close") { sheet = nil }.disabled(store.jobRunning)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 560)
        .interactiveDismissDisabled(store.jobRunning)
    }
}
