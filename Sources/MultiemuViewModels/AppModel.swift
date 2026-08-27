import Foundation
import MultiemuBackend
import MultiemuConfiguration
import MultiemuDisks
import MultiemuHost
import MultiemuImages
import MultiemuSupport
import Observation

/// Host capabilities in a form the interface can hold and pass around.
public struct HostCapabilitiesSnapshot: Sendable {
    public var capabilities: HostCapabilities
    public var blockingProblems: [String]

    public init(capabilities: HostCapabilities) {
        self.capabilities = capabilities
        self.blockingProblems = HostCapabilityProbe.blockingProblems(for: capabilities).map(\.remediation)
    }

    public var hardwareVirtualizationAvailable: Bool { capabilities.hardwareVirtualizationAvailable }
    public var cpuDescription: String { "\(capabilities.cpu.brand) · \(capabilities.cpu.architecture.displayName)" }
    public var memoryDescription: String { ByteCount.describe(capabilities.memory.physicalBytes) }
    public var recommendedVCPUCount: Int { capabilities.cpu.recommendedGuestVCPUCount }
    public var preferredGuestArchitecture: GuestArchitecture {
        BackendSelector.preferredGuestArchitecture(input: .init(host: capabilities)) ?? .arm64
    }
}

/// Top-level interface state.
@MainActor
@Observable
public final class AppModel {

    public private(set) var devices: [DeviceModel] = []
    public var selectedDeviceID: UUID? {
        didSet { updateGamepadOwnership() }
    }
    public private(set) var host: HostCapabilitiesSnapshot
    public private(set) var availableImages: [ImageManifest] = []
    /// Set when something the user asked for could not be done.
    public var lastError: String?
    /// Drives the new-device sheet.
    public var isCreatingDevice = false

    public let helpers: HelperLocator
    private let deviceStore: VirtualDeviceStore?
    /// Devices deleted on purpose, so the reconcile in `reload()` does not
    /// mistake one for a running device that fell out of the store.
    private var deletedDeviceIDs: Set<UUID> = []
    private let imageStore: ImageStore

    public init(
        helpers: HelperLocator = HelperLocator(),
        deviceRoot: URL = VirtualDeviceStore.defaultRoot(),
        imageRoot: URL = ImageStore.defaultRoot()
    ) {
        self.helpers = helpers
        self.host = HostCapabilitiesSnapshot(
            capabilities: HostCapabilityProbe(options: .init(runExternalToolVersionCommands: false)).collect()
        )
        self.imageStore = ImageStore(root: imageRoot)
        self.deviceStore = helpers.diskManager().map { VirtualDeviceStore(root: deviceRoot, disks: $0) }
        reload()
    }

    public var selectedDevice: DeviceModel? {
        devices.first { $0.id == selectedDeviceID }
    }

    /// Whether the application can create or run devices at all.
    public var isOperational: Bool { deviceStore != nil && host.blockingProblems.isEmpty }

    public var setupProblems: [String] {
        var problems = host.blockingProblems
        if deviceStore == nil {
            let resolution = helpers.locateDiskTool()
            problems.append("""
                qemu-img was not found, so virtual disks cannot be created. \
                Searched: \(resolution.searchedPaths.joined(separator: ", ")).
                """)
        }
        let emulator = helpers.locateEmulator(for: host.preferredGuestArchitecture)
        if !emulator.isAvailable {
            problems.append("""
                No emulator backend was found for \(host.preferredGuestArchitecture.displayName). \
                Searched: \(emulator.searchedPaths.joined(separator: ", ")).
                """)
        }
        return problems
    }

    /// Gives the game controller to the selected device and takes it from the
    /// rest. Exactly one device receives gamepad input at a time.
    private func updateGamepadOwnership() {
        for device in devices {
            device.setReceivesGamepadInput(device.id == selectedDeviceID)
        }
    }

    /// Devices that currently hold host resources.
    public var runningDevices: [DeviceModel] { devices.filter(\.isRunning) }

    /// What the running devices have already claimed, for admission control.
    ///
    /// `excluding` is the device being admitted. A starting device moves to
    /// `.starting` before it is validated — that is what makes the claim atomic
    /// against a sibling starting at the same moment — so without excluding it
    /// here it would be weighed against its own memory and a device large
    /// enough to fit the host alone would refuse itself.
    ///
    /// A configured storage size is only a claim on free space where the volume
    /// cannot allocate sparsely; elsewhere the image grows on demand and
    /// counting it up front would refuse admissions that would succeed.
    public func committedResources(excluding excluded: UUID? = nil) -> CommittedResources {
        let running = runningDevices.filter { $0.id != excluded }
        return CommittedResources.summing(
            running.map(\.profile.resources),
            hostPorts: Set(running.flatMap { $0.profile.network.portForwards.map(\.hostPort) })
        )
    }

    /// Everything currently committed, counting every running device.
    public var committedResources: CommittedResources { committedResources(excluding: nil) }

    /// Rebuilds the device list from the store, **reconciling** rather than
    /// replacing.
    ///
    /// Replacing was a real defect: creating a device calls this, and a fresh
    /// `DeviceModel` for an already-running device drops the only reference to
    /// its session. Nothing in the package has a `deinit`, so the QEMU child
    /// kept running while its row reset to inactive — unreachable and
    /// unstoppable. A running device therefore keeps its existing model, and
    /// only its profile is refreshed.
    public func reload() {
        guard let deviceStore else { return }
        availableImages = imageStore.installedImageIdentifiers().compactMap { try? imageStore.manifest(for: $0) }

        let existing = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reconciled: [DeviceModel] = []
        for profile in deviceStore.list() {
            if let model = existing[profile.id] {
                model.update(profile)
                reconciled.append(model)
            } else {
                reconciled.append(DeviceModel(
                    profile: profile, store: deviceStore, imageStore: imageStore,
                    helpers: helpers, host: host,
                    committedResources: { [weak self] id in
                        self?.committedResources(excluding: id) ?? .none
                    }
                ))
            }
        }

        // A device that vanished from the store while running is kept until it
        // stops; dropping it here would orphan its backend exactly as above.
        // A device the user deleted is exempt — it was stopped on purpose.
        for model in devices
        where model.isRunning
            && !deletedDeviceIDs.contains(model.id)
            && !reconciled.contains(where: { $0.id == model.id }) {
            reconciled.append(model)
        }
        deletedDeviceIDs.formIntersection(reconciled.map(\.id))

        devices = reconciled
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id
        }
        updateGamepadOwnership()
    }

    @discardableResult
    public func createDevice(
        name: String,
        imageIdentifier: String,
        memoryBytes: UInt64,
        storageBytes: UInt64,
        vcpuCount: Int,
        display: DisplayProfile
    ) -> DeviceModel? {
        guard let deviceStore else {
            lastError = "Virtual disks cannot be created without qemu-img."
            return nil
        }
        let profile = VirtualDeviceProfile(
            name: name,
            imageIdentifier: imageIdentifier,
            guestArchitecture: host.preferredGuestArchitecture,
            memoryBytes: memoryBytes,
            storageBytes: storageBytes,
            vcpuCount: vcpuCount,
            display: display
        )

        // Refuse before creating anything if the host cannot honour the request.
        // Deliberately validated with no committed total: creating a stopped
        // device claims nothing, and the sheet says "for one device". Admission
        // against what is already running belongs at start, in the session.
        let preflight = ResourceValidator.validate(profile.resources, host: host.capabilities)
        guard preflight.isAllowed else {
            lastError = preflight.errors.map(\.remediation).joined(separator: "\n")
            return nil
        }

        do {
            let created = try deviceStore.create(profile)
            reload()
            selectedDeviceID = created.id
            return devices.first { $0.id == created.id }
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    public func deleteDevice(_ device: DeviceModel) async {
        guard let deviceStore else { return }
        if device.isRunning { await device.forceStop() }
        // `forceStop` returns once the process is gone, but `state` only reaches
        // `.inactive` once that news travels back through the event stream. The
        // reconcile below retains any still-running device that has vanished
        // from the store — which, without this, would resurrect the device the
        // user just deleted, permanently.
        deletedDeviceIDs.insert(device.id)
        do {
            try deviceStore.delete(device.id)
            reload()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Saves the selected device's current frame into the user's Pictures
    /// folder, at the guest's own resolution.
    public func captureScreenshotOfSelection() {
        guard let device = selectedDevice else { return }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if device.captureScreenshot(to: pictures) == nil {
            lastError = device.lastError
        }
    }

    /// Whether the selected device can take a package right now.
    public var canInstallPackage: Bool { selectedDevice?.canInstallPackage == true }

    /// Installs an APK into the selected device.
    ///
    /// The panel is the caller's job — this takes a URL so the same path serves
    /// the menu item, a drag onto the display, and a test.
    public func installPackageIntoSelection(from url: URL) async {
        guard let device = selectedDevice else {
            lastError = "Select a device first."
            return
        }
        if await device.installPackage(at: url) == false {
            lastError = device.lastError
        }
    }

    /// Largest guest memory this Mac allows, for the settings sliders.
    public var maximumGuestMemoryBytes: UInt64 {
        ResourceValidator.maximumAllowedGuestMemory(physicalBytes: host.capabilities.memory.physicalBytes)
    }

    public var minimumGuestMemoryBytes: UInt64 { ResourceValidator.minimumGuestMemoryBytes }
}
