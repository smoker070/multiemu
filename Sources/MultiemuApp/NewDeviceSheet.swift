import MultiemuConfiguration
import MultiemuSupport
import MultiemuViewModels
import SwiftUI

struct NewDeviceSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Android Device"
    @State private var imageIdentifier = ""
    @State private var memoryGiB = 4.0
    @State private var storageGiB = 32.0
    @State private var vcpuCount = 4
    @State private var presetName = "1920 × 1080"

    private var display: DisplayProfile {
        DisplayProfile.preset(named: presetName) ?? .default
    }

    private var memoryRange: ClosedRange<Double> {
        let minimum = Double(model.minimumGuestMemoryBytes) / Double(ByteCount.giB)
        let maximum = max(minimum, Double(model.maximumGuestMemoryBytes) / Double(ByteCount.giB))
        return minimum...maximum
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(size: 34)
                Text("New Virtual Device").font(.title2.weight(.semibold))
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("System image", selection: $imageIdentifier) {
                        if model.availableImages.isEmpty {
                            Text("No images installed").tag("")
                        }
                        ForEach(model.availableImages, id: \.imageIdentifier) { image in
                            Text("\(image.displayName) · Android \(image.androidRelease)")
                                .tag(image.imageIdentifier)
                        }
                    }
                }

                Section("Resources") {
                    // The upper bound comes from this Mac, so the interface
                    // cannot offer a configuration preflight would refuse.
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Memory")
                            Spacer()
                            Text(ByteCount.describe(UInt64(memoryGiB * Double(ByteCount.giB))))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $memoryGiB, in: memoryRange, step: 1)
                        Text("This Mac allows up to \(ByteCount.describe(model.maximumGuestMemoryBytes)) for one device.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Picker("Storage", selection: $storageGiB) {
                        ForEach([16.0, 32.0, 64.0, 128.0], id: \.self) { size in
                            Text("\(Int(size)) GiB").tag(size)
                        }
                    }

                    Stepper(value: $vcpuCount, in: 1...max(1, model.host.capabilities.cpu.logicalCores)) {
                        HStack {
                            Text("Processors")
                            Spacer()
                            Text("\(vcpuCount)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Text("Recommended for this Mac: \(model.host.recommendedVCPUCount).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Display") {
                    Picker("Resolution", selection: $presetName) {
                        Section("Landscape") {
                            ForEach(DisplayProfile.landscapePresets, id: \.name) { Text($0.name).tag($0.name) }
                        }
                        Section("Portrait") {
                            ForEach(DisplayProfile.portraitPresets, id: \.name) { Text($0.name).tag($0.name) }
                        }
                    }
                    LabeledContent("Density", value: "\(display.densityDPI) dpi")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text("Storage grows as the guest uses it; it is not reserved up front.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    model.createDevice(
                        name: name,
                        imageIdentifier: imageIdentifier,
                        memoryBytes: UInt64(memoryGiB * Double(ByteCount.giB)),
                        storageBytes: UInt64(storageGiB * Double(ByteCount.giB)),
                        vcpuCount: vcpuCount,
                        display: display
                    )
                    if model.lastError == nil { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || imageIdentifier.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            imageIdentifier = model.availableImages.first?.imageIdentifier ?? ""
            memoryGiB = min(max(4, memoryRange.lowerBound), memoryRange.upperBound)
            vcpuCount = model.host.recommendedVCPUCount
        }
    }
}

struct DeviceSettingsSheet: View {
    @Bindable var device: DeviceModel
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var memoryGiB = 4.0
    @State private var vcpuCount = 4
    @State private var presetName = "1920 × 1080"
    @State private var audioEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(device.name) Settings").font(.title2.weight(.semibold)).padding(20)
            Divider()

            Form {
                Section { TextField("Name", text: $name) }

                Section("Resources") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Memory")
                            Spacer()
                            Text(ByteCount.describe(UInt64(memoryGiB * Double(ByteCount.giB))))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $memoryGiB,
                            in: Double(model.minimumGuestMemoryBytes) / Double(ByteCount.giB)
                                ... Double(model.maximumGuestMemoryBytes) / Double(ByteCount.giB),
                            step: 1
                        )
                    }
                    Stepper(value: $vcpuCount, in: 1...max(1, model.host.capabilities.cpu.logicalCores)) {
                        HStack {
                            Text("Processors")
                            Spacer()
                            Text("\(vcpuCount)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Display") {
                    Picker("Resolution", selection: $presetName) {
                        ForEach(DisplayProfile.allPresets, id: \.name) { Text($0.name).tag($0.name) }
                    }
                }

                Section("Audio") {
                    Toggle("Sound output", isOn: $audioEnabled)
                    // Said plainly, because the alternative is a user turning
                    // this on, hearing nothing, and concluding the emulator is
                    // broken. The device is attached and works — what is
                    // missing is on the guest's side.
                    Text("""
                        Attaches a sound device and plays it through this Mac. \
                        Takes effect the next time this device starts. The Android \
                        images available today route app audio to a stub driver that \
                        never reaches the device, so apps stay silent on them.
                        """)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Storage") {
                    LabeledContent("Size", value: ByteCount.describe(device.profile.storageBytes))
                    Text("Storage cannot be resized after a device is created; create a new device instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var updated = device.profile
                    updated.name = name
                    updated.memoryBytes = UInt64(memoryGiB * Double(ByteCount.giB))
                    updated.vcpuCount = vcpuCount
                    updated.display = DisplayProfile.preset(named: presetName) ?? updated.display
                    updated.audioEnabled = audioEnabled
                    device.update(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 520, height: 600)
        .onAppear {
            name = device.profile.name
            memoryGiB = Double(device.profile.memoryBytes) / Double(ByteCount.giB)
            vcpuCount = device.profile.vcpuCount
            presetName = DisplayProfile.allPresets
                .first { $0.profile == device.profile.display }?.name ?? "1920 × 1080"
            // `nil` means a profile saved before audio existed, which is off.
            audioEnabled = device.profile.audioEnabled == true
        }
    }
}
