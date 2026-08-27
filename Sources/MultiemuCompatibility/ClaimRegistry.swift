import Foundation

/// Every claim the compatibility matrix makes.
///
/// This is the source of truth; `docs/COMPATIBILITY-MATRIX.md` is generated
/// from running it. A claim cannot be added here without naming what backs it,
/// and a claim whose evidence is out of reach has to say why rather than sit at
/// an optimistic default.
public enum ClaimRegistry {

    /// Spikes need a guest kernel. Filled in by the runner.
    public static let kernelPlaceholder = "@KERNEL@"
    public static let initrdPlaceholder = "@INITRD@"

    private static let guestArguments = [
        "--kernel", kernelPlaceholder, "--initrd", initrdPlaceholder,
    ]

    public static let all: [CompatibilityClaim] = [

        // MARK: Host and guest architecture

        CompatibilityClaim(
            id: "host.selection",
            section: .hostAndGuest,
            capability: "A backend is selected from real host capabilities",
            primary: .suite("Backend selection matrix"),
            intel: .sameAsPrimary,
            milestone: "M1",
            note: "The selection logic is host-independent; which backend it picks on an Intel Mac is untested."),
        CompatibilityClaim(
            id: "host.capabilities",
            section: .hostAndGuest,
            capability: "Host capabilities are probed rather than assumed",
            primary: .suite("HostCapabilityProbe"),
            intel: .unavailable(reason: "no Intel host is available to this project"),
            milestone: "M1"),
        CompatibilityClaim(
            id: "host.resources",
            section: .hostAndGuest,
            capability: "A device is refused when the host cannot honour it",
            primary: .suite("Resource preflight"),
            intel: .sameAsPrimary,
            milestone: "M1"),

        // MARK: Android versions
        //
        // Kept as claims rather than prose so they are counted, and so they
        // cannot quietly read as supported while no Android guest has run.

        CompatibilityClaim(
            id: "android.modern",
            section: .androidVersions,
            capability: "A modern Android release boots and runs (17 verified)",
            primary: .unavailable(reason: "Android 17 (SDK 37) boots to sys.boot_completed in 3.46 s median, launcher resumed — verified by hand and recorded in VERIFY.md -> CUTTLEFISH-WITHOUT-CVD. Not run by this harness: it needs a locally installed image, which is not in the repository."),
            intel: .unavailable(reason: "no Intel host is available, and the image obtained is arm64"),
            milestone: "M4",
            note: "The development target: best virtio support, so it is validated first."),
        CompatibilityClaim(
            id: "android.nine",
            section: .androidVersions,
            capability: "Android 9 (API 28) boots and runs",
            primary: .unavailable(reason: "no Android 9 image has been obtained; the image in use is Android 17"),
            intel: .unavailable(reason: "no Android 9 image has been obtained; the image in use is Android 17"),
            milestone: "M4",
            note: "The product floor, and expected to be the hardest target: it predates much of the virtio and generic-kernel work. Validated last."),

        // MARK: Boot and lifecycle

        CompatibilityClaim(
            id: "boot.linux",
            section: .boot,
            capability: "A Linux guest boots to userspace under hardware virtualization",
            primary: .suiteAndSpike(
                suite: "Guest boot probe",
                product: "multiemu-multi-instance-spike",
                arguments: guestArguments + ["--devices", "1", "--memory-gib", "2"]),
            milestone: "M2"),
        CompatibilityClaim(
            id: "boot.android",
            section: .boot,
            capability: "An Android guest boots",
            primary: .unavailable(reason: "Android 17 (SDK 37) boots to sys.boot_completed in 3.46 s median, launcher resumed — verified by hand and recorded in VERIFY.md -> CUTTLEFISH-WITHOUT-CVD. Not run by this harness: it needs a locally installed image, which is not in the repository."),
            intel: .unavailable(reason: "no Intel host is available, and the image obtained is arm64"),
            milestone: "M4"),
        CompatibilityClaim(
            id: "lifecycle.state",
            section: .boot,
            capability: "The lifecycle state machine survives its backend dying",
            primary: .suite("Emulator session"),
            intel: .sameAsPrimary,
            milestone: "M3"),
        CompatibilityClaim(
            id: "lifecycle.qmp",
            section: .boot,
            capability: "The QMP control channel drives a live guest",
            primary: .suite("QMP client"),
            milestone: "M3"),

        // MARK: Graphics and display

        CompatibilityClaim(
            id: "graphics.frames",
            section: .graphics,
            capability: "Guest frames arrive over D-Bus and decode",
            primary: .suite("D-Bus framebuffer decoding"),
            milestone: "M5"),
        CompatibilityClaim(
            id: "graphics.metal",
            section: .graphics,
            capability: "Frames are presented through Metal at guest resolution",
            primary: .suite("Metal presentation"),
            milestone: "M5"),
        CompatibilityClaim(
            id: "graphics.scaling",
            section: .graphics,
            capability: "Scaling modes preserve the guest's aspect ratio",
            primary: .suite("Display scaling geometry"),
            intel: .sameAsPrimary,
            milestone: "M5"),
        CompatibilityClaim(
            id: "graphics.performance",
            section: .graphics,
            capability: "The host frame path fits inside a 60 fps budget",
            primary: .suite("Presentation performance"),
            milestone: "M5"),
        CompatibilityClaim(
            id: "display.presets",
            section: .graphics,
            capability: "Every display preset applies to a running guest",
            primary: .suiteAndSpike(
                suite: "Display control",
                product: "multiemu-display-control-spike",
                arguments: guestArguments + ["--settle", "5"]),
            milestone: "M12"),
        CompatibilityClaim(
            id: "display.rotation",
            section: .graphics,
            capability: "The guest display rotates at runtime",
            primary: .spike(
                product: "multiemu-display-control-spike",
                arguments: guestArguments + ["--settle", "5"]),
            milestone: "M12"),
        CompatibilityClaim(
            id: "recording.file",
            section: .graphics,
            capability: "The guest display records to a playable file in real time",
            primary: .suiteAndSpike(
                suite: "Screen recording",
                product: "multiemu-recording-spike",
                arguments: guestArguments + ["--seconds", "4", "--fps", "30"]),
            milestone: "M13"),
        CompatibilityClaim(
            id: "recording.cost",
            section: .graphics,
            capability: "Recording does not slow the interactive frame path",
            primary: .suite("Recording performance"),
            intel: .sameAsPrimary,
            milestone: "M13"),

        // MARK: Input

        CompatibilityClaim(
            id: "input.keyboard",
            section: .input,
            capability: "Host keys map to Linux evdev codes the guest accepts",
            primary: .suite("Keyboard mapping"),
            intel: .sameAsPrimary,
            milestone: "M6"),
        CompatibilityClaim(
            id: "input.pointer",
            section: .input,
            capability: "Pointer coordinates map into guest space",
            primary: .suite("Pointer coordinate mapping"),
            intel: .sameAsPrimary,
            milestone: "M6"),
        CompatibilityClaim(
            id: "input.mapping",
            section: .input,
            capability: "Keys and gamepad controls map to screen positions",
            primary: .suiteAndSpike(
                suite: "Input mapping",
                product: "multiemu-input-mapping-spike",
                arguments: guestArguments),
            intel: .sameAsPrimary,
            milestone: "M16"),
        CompatibilityClaim(
            id: "input.profiles",
            section: .input,
            capability: "Input profiles persist per device and older files still open",
            primary: .suite("Input profile persistence"),
            intel: .sameAsPrimary,
            milestone: "M16"),
        CompatibilityClaim(
            id: "input.gamepad.hardware",
            section: .input,
            capability: "A physical game controller drives a guest",
            primary: .unavailable(
                reason: "no controller is available, and GCVirtualController does not exist on macOS"),
            intel: .unavailable(reason: "no controller is available"),
            milestone: "M16"),
        CompatibilityClaim(
            id: "input.guestObserved",
            section: .input,
            capability: "A guest reads the touch coordinates that were sent",
            primary: .blocked(by: "M16", reason: "the Linux fixture exports no evdev interface; an Android guest now boots, but guest-side touch delivery has not been checked in it"),
            intel: .blocked(by: "M16", reason: "the Linux fixture exports no evdev interface; an Android guest now boots, but guest-side touch delivery has not been checked in it"),
            milestone: "M16"),

        // MARK: Storage and snapshots

        CompatibilityClaim(
            id: "storage.disks",
            section: .storage,
            capability: "Virtual disks are created sparsely through qemu-img",
            primary: .suite("Virtual disks"),
            milestone: "M9"),
        CompatibilityClaim(
            id: "storage.profiles",
            section: .storage,
            capability: "Device profiles persist and reload faithfully",
            primary: .suite("Virtual device store"),
            intel: .sameAsPrimary,
            milestone: "M9"),
        CompatibilityClaim(
            id: "storage.persistence",
            section: .storage,
            capability: "Guest data survives a full restart",
            primary: .spike(
                product: "multiemu-persistence-spike",
                arguments: guestArguments + ["--shell-delay", "12"]),
            milestone: "M9"),
        CompatibilityClaim(
            id: "storage.snapshots",
            section: .storage,
            capability: "Snapshots capture and restore RAM as well as disk",
            primary: .suiteAndSpike(
                suite: "Snapshots",
                product: "multiemu-snapshot-spike",
                arguments: guestArguments),
            milestone: "M15"),
        CompatibilityClaim(
            id: "storage.images",
            section: .storage,
            capability: "Android images are verified before boot and their headers parsed",
            primary: .suite("Android boot image"),
            intel: .sameAsPrimary,
            milestone: "M4"),
        CompatibilityClaim(
            id: "storage.composite",
            section: .storage,
            capability: "A GPT composite disk is built as Android expects",
            primary: .suite("GPT composite disk"),
            intel: .sameAsPrimary,
            milestone: "M4"),

        // MARK: Networking

        CompatibilityClaim(
            id: "network.configuration",
            section: .networking,
            capability: "Guest networking is configured, and forwards validated",
            primary: .suite("Guest networking configuration"),
            intel: .sameAsPrimary,
            milestone: "M7"),
        CompatibilityClaim(
            id: "network.loopback",
            section: .networking,
            capability: "Traffic flows both ways, and forwards bind loopback only",
            primary: .spike(product: "multiemu-network-spike", arguments: guestArguments),
            milestone: "M7"),
        CompatibilityClaim(
            id: "network.ports",
            section: .networking,
            capability: "Host ports are allocated without collision",
            primary: .suite("Host port allocation"),
            intel: .sameAsPrimary,
            milestone: "M7"),
        CompatibilityClaim(
            id: "network.adb",
            section: .networking,
            capability: "A device appears in `adb devices` and a shell works",
            primary: .unavailable(reason: "ADB connects and `shell:` works over the loopback forward once the guest is routed (ip route add 10.0.2.0/24 dev buried_eth0 table local_network — Android never consults the main table) and adbd is switched to TCP; see scripts/enable-guest-adb.sh. Not run by this harness: it needs a booted guest and a locally installed image"),
            intel: .unavailable(reason: "no Intel host is available; the guest-side fix is host-independent"),
            milestone: "M8"),

        // MARK: File exchange and clipboard

        CompatibilityClaim(
            id: "sharing.confinement",
            section: .sharing,
            capability: "Guest-supplied paths stay confined to the shared folder",
            primary: .suiteAndSpike(
                suite: "Shared folder confinement",
                product: "multiemu-sharing-spike",
                arguments: guestArguments),
            intel: .sameAsPrimary,
            milestone: "M14"),
        CompatibilityClaim(
            id: "sharing.arguments",
            section: .sharing,
            capability: "A shared folder is exported read-only, with its path escaped",
            primary: .suite("Shared folder arguments"),
            intel: .sameAsPrimary,
            milestone: "M14"),
        CompatibilityClaim(
            id: "sharing.guestReadable",
            section: .sharing,
            capability: "A shared directory is readable inside the guest",
            primary: .blocked(by: "M14", reason: "no transport in common: the host offers only virtio-9p and the Android guest supports only virtiofs (no 9p in /proc/filesystems, no 9p module). QEMU on macOS exposes no virtio-fs device and there is no virtiofsd"),
            intel: .blocked(by: "M14", reason: "no transport in common: the host offers only virtio-9p and the Android guest supports only virtiofs (no 9p in /proc/filesystems, no 9p module). QEMU on macOS exposes no virtio-fs device and there is no virtiofsd"),
            milestone: "M14"),
        CompatibilityClaim(
            id: "clipboard.roundTrip",
            section: .sharing,
            capability: "Clipboard text crosses in both directions",
            primary: .blocked(by: "M14", reason: "QEMU mediates clipboard to a guest agent, which no stock Android image runs; the ADB route Google uses needs M8, blocked by the same image lacking virtio_net"),
            intel: .blocked(by: "M4", reason: "QEMU needs a guest clipboard agent"),
            milestone: "M14"),

        // MARK: Multiple devices

        CompatibilityClaim(
            id: "multi.concurrent",
            section: .multiInstance,
            capability: "Several devices run at once with separate helper processes",
            primary: .spike(
                product: "multiemu-multi-instance-spike",
                arguments: guestArguments + ["--devices", "2", "--memory-gib", "2"]),
            milestone: "M18"),
        CompatibilityClaim(
            id: "multi.admission",
            section: .multiInstance,
            capability: "Admission accounts for devices already running",
            primary: .suiteAndSpike(
                suite: "Multi-instance admission",
                product: "multiemu-multi-instance-spike",
                arguments: guestArguments + ["--devices", "6", "--memory-gib", "2", "--concurrent"]),
            intel: .sameAsPrimary,
            milestone: "M18"),

        // MARK: Application and packaging

        CompatibilityClaim(
            id: "app.helpers",
            section: .packaging,
            capability: "The application finds its helper binaries, and says which it used",
            primary: .suite("Helper location"),
            intel: .sameAsPrimary,
            milestone: "M17"),
        CompatibilityClaim(
            id: "app.arguments",
            section: .packaging,
            capability: "The QEMU command line is built as intended",
            primary: .suite("QEMU command line"),
            intel: .sameAsPrimary,
            milestone: "M2"),
        // Not signed by decision rather than by obstacle. Multiemu is MIT open
        // source with no Apple Developer membership behind it, and
        // `release.sh --unsigned` is the supported path. Reporting this as
        // "unavailable" would read as something the project is still waiting
        // for, which it is not.
        CompatibilityClaim(
            id: "app.notarization",
            section: .packaging,
            capability: "A signed, notarized DMG installs on a clean Mac",
            primary: .unavailable(
                reason: "not signed by choice: this project ships an unsigned, MIT-licensed build "
                    + "(`release.sh --unsigned`). The signed pipeline exists and rehearses end to end "
                    + "for anyone who wants one"),
            intel: .unavailable(
                reason: "not signed by choice; see the primary row"),
            milestone: "M21"),
        CompatibilityClaim(
            id: "app.dmg",
            section: .packaging,
            capability: "A disk image builds, mounts, and carries an app that still verifies",
            primary: .script(path: "scripts/make-dmg.sh"),
            intel: .sameAsPrimary,
            milestone: "M21",
            note: "Checked by scripts/make-dmg.sh, which mounts the image it just built and verifies the bundle inside it."),

        // MARK: Failure and edge cases

        CompatibilityClaim(
            id: "failure.backendCrash",
            section: .failures,
            capability: "A backend killed from outside is detected and recovered from",
            primary: .suite("Emulator session"),
            milestone: "M3"),
        CompatibilityClaim(
            id: "failure.badImage",
            section: .failures,
            capability: "A corrupt or missing guest image fails as itself, not as a timeout",
            primary: .suite("Image store"),
            intel: .sameAsPrimary,
            milestone: "M4"),
        CompatibilityClaim(
            id: "failure.availability",
            section: .failures,
            capability: "An unavailable backend is reported with a remedy",
            primary: .suite("Backend availability"),
            intel: .sameAsPrimary,
            milestone: "M2"),
    ]
}
