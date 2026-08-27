import Foundation
import MultiemuBackend
import MultiemuConfiguration
import MultiemuDisks
import MultiemuSupport

// multiemu-device — create, list and remove virtual devices from the terminal.
//
// The companion to `multiemu-image`. It exists so devices can be prepared for
// automated interface checks and support diagnostics without clicking through
// the application, and it uses exactly the same store the application does.

setvbuf(stdout, nil, _IONBF, 0)

let help = """
multiemu-device — manage virtual devices

USAGE:
  multiemu-device list [--root <dir>]
  multiemu-device create --name <name> --image <identifier>
                         [--memory-gib <n>] [--storage-gib <n>] [--cpus <n>]
                         [--display "1920 × 1080"] [--root <dir>]
  multiemu-device delete <device-id> [--root <dir>]
  multiemu-device reset <device-id> [--root <dir>]

OPTIONS:
  --root <dir>   Device store root. Default:
                 ~/Library/Application Support/Multiemu/devices
"""

@MainActor func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(value)")
}
@MainActor func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("multiemu-device: \(message)\n".utf8))
    exit(code)
}

var argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first, !["-h", "--help"].contains(command) else {
    print(help); exit(argv.isEmpty ? 64 : 0)
}
argv.removeFirst()

@MainActor func option(_ name: String) -> String? {
    guard let index = argv.firstIndex(of: name), index + 1 < argv.count else { return nil }
    return argv[index + 1]
}

let root = option("--root").map { URL(fileURLWithPath: $0) } ?? VirtualDeviceStore.defaultRoot()
guard let disks = VirtualDiskManager.locateDevelopmentTool() else {
    fail("qemu-img not found; virtual disks cannot be managed", code: 65)
}
let store = VirtualDeviceStore(root: root, disks: disks)

switch command {

case "list":
    let devices = store.list()
    if devices.isEmpty { print("No virtual devices in \(root.path)"); exit(0) }
    print("Virtual devices in \(root.path)")
    for device in devices {
        print("")
        print("  \(device.name)")
        row("id", device.id.uuidString)
        row("image", device.imageIdentifier)
        row("architecture", device.guestArchitecture.displayName)
        row("resources", "\(device.vcpuCount) vCPU · \(ByteCount.describe(device.memoryBytes)) · \(ByteCount.describe(device.storageBytes))")
        row("display", "\(device.display.widthInPixels)×\(device.display.heightInPixels) @ \(device.display.densityDPI) dpi")
        let userdata = store.userdataURL(for: device.id)
        if let disk = try? disks.inspect(at: userdata), let allocated = disk.allocatedBytes() {
            row("userdata", "\(ByteCount.describe(allocated)) allocated of \(ByteCount.describe(disk.logicalSizeBytes))")
        }
        if let snapshots = try? disks.snapshots(at: userdata), !snapshots.isEmpty {
            row("snapshots", snapshots.map(\.tag).joined(separator: ", "))
        }
    }

case "create":
    guard let name = option("--name"), let image = option("--image") else {
        fail("create requires --name and --image\n\n\(help)", code: 64)
    }
    let memory = UInt64(option("--memory-gib") ?? "4") ?? 4
    let storage = UInt64(option("--storage-gib") ?? "32") ?? 32
    let cpus = Int(option("--cpus") ?? "4") ?? 4
    let display = option("--display").flatMap(DisplayProfile.preset(named:)) ?? .default

    do {
        let created = try store.create(VirtualDeviceProfile(
            name: name, imageIdentifier: image,
            guestArchitecture: .arm64,
            memoryBytes: memory * ByteCount.giB,
            storageBytes: storage * ByteCount.giB,
            vcpuCount: cpus, display: display
        ))
        print("Created \(created.name)")
        row("id", created.id.uuidString)
        row("userdata", store.userdataURL(for: created.id).path)
    } catch {
        fail("\(error)")
    }

case "delete", "reset":
    guard let identifier = argv.first, let id = UUID(uuidString: identifier) else {
        fail("\(command) requires a device id (see `multiemu-device list`)", code: 64)
    }
    do {
        if command == "delete" {
            try store.delete(id)
            print("Deleted \(id.uuidString)")
        } else {
            try store.factoryReset(id)
            print("Factory reset \(id.uuidString)")
        }
    } catch {
        fail("\(error)")
    }

default:
    fail("unknown command '\(command)'\n\n\(help)", code: 64)
}
