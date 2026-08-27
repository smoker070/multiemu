import Darwin
import Foundation
import MultiemuBackend
import MultiemuImages
import MultiemuSupport

// multiemu-image — inspect, verify and unpack Android image sets.
//
// `inspect` is the tool that will validate the boot image parser against a real
// Google- or AOSP-produced image (docs/VERIFY.md → BOOT-IMAGE-HEADER-LAYOUT).
// Point it at any boot.img or vendor_boot.img; it reads the header only and
// never executes anything.

let help = """
multiemu-image — inspect, verify and unpack Android image sets

USAGE:
  multiemu-image inspect <path-to-boot.img|vendor_boot.img>
  multiemu-image list [--root <dir>]
  multiemu-image verify <image-identifier> [--root <dir>]
  multiemu-image unpack <image-identifier> [--root <dir>]
  multiemu-image traits <image-identifier> [--apply]
  multiemu-image plan <directory>
  multiemu-image composite <image-identifier> --out <disk.img>
                 [--userdata-gib <n>] [--slot-suffix <s>] [--root <dir>]
                 [--relax-verified-boot]
  multiemu-image install <directory> --id <identifier> --release <n> --api <n>
                 --arch <arm64|x86_64> --source <text> --license <text>
                 [--name <text>] [--karg <arg>]... [--root <dir>]

OPTIONS:
  --root <dir>   Image store root. Default:
                 ~/Library/Application Support/Multiemu/images
  -h, --help     Show this help.

  --relax-verified-boot
                 Turn off Android Verified Boot in the generated disk. The
                 guest will then mount partitions whose signature nothing
                 checked. Needed for AOSP images, which are signed with test
                 keys no device trusts. The installed image is not modified,
                 and its SHA-256 is still verified before every boot.

EXIT CODES:
  0  success
  2  the image is invalid, corrupt, or failed verification
  64 bad usage
  66 file or image not found
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("multiemu-image: \(message)\n".utf8))
    exit(code)
}

func row(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(value)")
}

func describeRange(_ range: Range<Int>?) -> String {
    guard let range else { return "absent" }
    return "\(ByteCount.describe(UInt64(range.count))) at offset \(range.lowerBound)"
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--help") {
    print(help)
    exit(arguments.isEmpty ? 64 : 0)
}

let command = arguments.removeFirst()

var storeRoot = ImageStore.defaultRoot()
if let index = arguments.firstIndex(of: "--root"), index + 1 < arguments.count {
    storeRoot = URL(fileURLWithPath: arguments[index + 1])
    arguments.removeSubrange(index...(index + 1))
}
let store = ImageStore(root: storeRoot)

switch command {

case "inspect":
    guard let path = arguments.first else { fail("inspect needs a file path.\n\n\(help)", code: 64) }
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("Cannot read \(path)", code: 66)
    }

    print("multiemu-image inspect")
    row("file", path)
    row("size", ByteCount.describe(UInt64(data.count)))
    row("sha256", (try? ImageStore.sha256(ofFileAt: URL(fileURLWithPath: path))) ?? "unavailable")

    let magic = String(decoding: data.prefix(8), as: UTF8.self)
    row("magic", magic)
    print("")

    switch magic {
    case AndroidBootImage.bootMagic:
        do {
            let boot = try AndroidBootImage.parseBootImage(data)
            print("Android boot image")
            row("header version", "\(boot.headerVersion)")
            row("page size", "\(boot.pageSize)")
            row("product name", boot.productName.isEmpty ? "(none)" : boot.productName)
            row("os version", boot.osVersion ?? "(not recorded)")
            row("security patch", boot.osPatchLevel ?? "(not recorded)")
            row("kernel", describeRange(boot.kernelRange))
            row("ramdisk", describeRange(boot.ramdiskRange))
            row("second stage", describeRange(boot.secondStageRange))
            row("recovery dtbo", describeRange(boot.recoveryDTBORange))
            row("dtb", describeRange(boot.dtbRange))
            print("")
            print("  kernel command line:")
            print("    \(boot.kernelCommandLine.isEmpty ? "(empty)" : boot.kernelCommandLine)")
        } catch {
            fail("\(error)", code: 2)
        }

    case AndroidBootImage.vendorBootMagic:
        do {
            let vendor = try AndroidBootImage.parseVendorBootImage(data)
            print("Android vendor boot image")
            row("header version", "\(vendor.headerVersion)")
            row("page size", "\(vendor.pageSize)")
            row("product name", vendor.productName.isEmpty ? "(none)" : vendor.productName)
            row("vendor ramdisk", describeRange(vendor.vendorRamdiskRange))
            row("dtb", describeRange(vendor.dtbRange))
            row("bootconfig", describeRange(vendor.bootconfigRange))
            print("")
            print("  kernel command line:")
            print("    \(vendor.kernelCommandLine.isEmpty ? "(empty)" : vendor.kernelCommandLine)")
        } catch {
            fail("\(error)", code: 2)
        }

    default:
        fail("""
            Not an Android boot container. Expected magic \
            "\(AndroidBootImage.bootMagic)" or "\(AndroidBootImage.vendorBootMagic)", found "\(magic)".
            """, code: 2)
    }

case "list":
    let identifiers = store.installedImageIdentifiers()
    if identifiers.isEmpty {
        print("No images installed under \(storeRoot.path)")
        exit(0)
    }
    print("Installed images in \(storeRoot.path)")
    for identifier in identifiers {
        guard let manifest = try? store.manifest(for: identifier) else {
            print("  \(identifier)  (manifest unreadable)")
            continue
        }
        print("  \(identifier)")
        row("name", manifest.displayName)
        row("android", "\(manifest.androidRelease) (API \(manifest.androidAPILevel))")
        row("architecture", manifest.guestArchitecture.displayName)
        row("source", manifest.source)
        row("redistribution", manifest.licenseNotice)
        row("files", "\(manifest.files.count)")
    }

case "verify":
    guard let identifier = arguments.first else { fail("verify needs an image identifier.", code: 64) }
    do {
        let report = try store.verify(identifier)
        print("Verification of \(identifier)")
        row("files checked", "\(report.checkedFiles)")
        row("verdict", report.isIntact ? "intact" : "FAILED")
        for problem in report.problems { print("    \(problem)") }
        exit(report.isIntact ? 0 : 2)
    } catch {
        fail("\(error)", code: 2)
    }

case "unpack":
    guard let identifier = arguments.first else { fail("unpack needs an image identifier.", code: 64) }
    do {
        let report = try store.verify(identifier)
        guard report.isIntact else {
            fail("Refusing to unpack an image that failed verification: \(report.problems.joined(separator: " "))", code: 2)
        }
        let result = try store.unpackBootImages(for: identifier)
        print("Unpacked \(identifier)")
        row("kernel", result.kernelURL.path)
        row("ramdisk", result.ramdiskURL?.path ?? "(none)")
        row("dtb", result.deviceTreeURL?.path ?? "(none)")
        row("header version", "\(result.detectedHeaderVersion)")
        print("")
        print("  boot.img command line:")
        print("    \(result.bootImageCommandLine.isEmpty ? "(empty)" : result.bootImageCommandLine)")
        if let vendorCommandLine = result.vendorBootCommandLine {
            print("  vendor_boot.img command line:")
            print("    \(vendorCommandLine.isEmpty ? "(empty)" : vendorCommandLine)")
        }
    } catch {
        fail("\(error)", code: 2)
    }

case "plan":
    guard let path = arguments.first else { fail("plan needs a directory.", code: 64) }
    do {
        let plan = try ImageInstaller(store: store).plan(forDirectory: URL(fileURLWithPath: path))
        print("Image set in \(path)")
        for entry in plan.recognised {
            row(entry.role.rawValue, "\(entry.filename)  \(ByteCount.describe(entry.sizeBytes))")
        }
        if !plan.unrecognised.isEmpty {
            print("")
            print("  Unrecognised .img files (not installed):")
            for name in plan.unrecognised { print("    \(name)") }
        }
        if plan.recognised.isEmpty { exit(2) }
    } catch {
        fail("\(error)", code: 66)
    }

case "install":
    guard let path = arguments.first else { fail("install needs a directory.", code: 64) }
    arguments.removeFirst()

    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    func repeatedOption(_ name: String) -> [String] {
        var values: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == name, index + 1 < arguments.count { values.append(arguments[index + 1]) }
            index += 1
        }
        return values
    }

    guard let identifier = option("--id"),
          let release = option("--release"),
          let apiText = option("--api"), let api = Int(apiText),
          let archText = option("--arch"), let architecture = GuestArchitecture(rawValue: archText),
          let source = option("--source"),
          let license = option("--license") else {
        fail("install requires --id, --release, --api, --arch, --source and --license.\n\n\(help)", code: 64)
    }

    do {
        let manifest = try ImageInstaller(store: store).install(
            fromDirectory: URL(fileURLWithPath: path),
            identifier: identifier,
            displayName: option("--name") ?? identifier,
            androidRelease: release,
            androidAPILevel: api,
            guestArchitecture: architecture,
            source: source,
            licenseNotice: license,
            requiredKernelArguments: repeatedOption("--karg"),
            progress: { print("  \($0)") }
        )
        print("")
        print("Installed \(manifest.imageIdentifier) into \(storeRoot.path)")
        row("android", "\(manifest.androidRelease) (API \(manifest.androidAPILevel))")
        row("files", "\(manifest.files.count)")

        // Ask the image what it needs to boot, unless the caller already said.
        //
        // An image installed without these boots to a stalled second stage and
        // sits there until the timeout — which reads as "the emulator is very
        // slow" rather than as a missing argument. Explicit --karg wins: a
        // person who states an argument means it.
        let explicit = repeatedOption("--karg")
        if explicit.isEmpty, !arguments.contains("--no-detect") {
            print("")
            print("Reading the image's own boot requirements…")
            do {
                let unpacked = try store.unpackBootImages(for: identifier)
                guard let ramdisk = unpacked.ramdiskURL else {
                    throw AndroidRamdisk.Failure.unreadable("the image has no ramdisk")
                }
                let userdata = manifest.file(for: .userdata).map { store.url(of: $0, in: identifier) }
                let filesystem = try userdata.map { try AndroidImageTraits.filesystem(ofPartitionAt: $0) }
                    ?? .unknown
                let detection = AndroidImageTraits.detect(
                    ramdiskEntries: try AndroidRamdisk.entryNames(at: ramdisk),
                    userdataFilesystem: filesystem)

                for line in detection.evidence { print("    \(line)") }
                if detection.kernelArguments.isEmpty {
                    print("")
                    print("  Nothing could be derived. This image will need --karg values;")
                    print("  without them the guest stalls in second-stage init.")
                } else {
                    try store.updateRequiredKernelArguments(
                        detection.kernelArguments, layout: detection.partitionLayout,
                        for: identifier)
                    print("")
                    row("detected arguments", "\(detection.kernelArguments.count)")
                    for argument in detection.kernelArguments { print("      \(argument)") }
                }
            } catch {
                print("    could not read the image: \(error)")
                print("    install succeeded; supply --karg values yourself before booting.")
            }
        } else if !explicit.isEmpty {
            print("")
            print("  Using the \(explicit.count) argument(s) given with --karg; detection skipped.")
        }

        print("")
        print("Next: multiemu-image unpack \(identifier)")
    } catch {
        fail("\(error)", code: 2)
    }

case "traits":
    guard let identifier = arguments.first else {
        fail("traits needs an image identifier.", code: 64)
    }
    do {
        let manifest = try store.manifest(for: identifier)
        let unpacked = try store.unpackBootImages(for: identifier)
        guard let ramdisk = unpacked.ramdiskURL else { fail("that image has no ramdisk.", code: 2) }
        let userdata = manifest.file(for: .userdata).map { store.url(of: $0, in: identifier) }
        let filesystem = try userdata.map { try AndroidImageTraits.filesystem(ofPartitionAt: $0) } ?? .unknown
        let detection = AndroidImageTraits.detect(
            ramdiskEntries: try AndroidRamdisk.entryNames(at: ramdisk),
            userdataFilesystem: filesystem)

        print("multiemu-image traits")
        row("image", identifier)
        row("board", detection.board ?? "not identified")
        row("userdata filesystem", detection.filesystem.rawValue)
        row("fstab variants", detection.availableFstabSuffixes.joined(separator: ", "))
        row("chosen fstab", detection.fstabSuffix ?? "none")
        row("partition layout", detection.partitionLayout?.rawValue ?? "not determined")
        print("")
        print("  How each answer was reached:")
        for line in detection.evidence { print("    - \(line)") }
        print("")
        print("  Kernel arguments this image needs:")
        if detection.kernelArguments.isEmpty {
            print("    (none could be derived)")
        } else {
            for argument in detection.kernelArguments { print("    \(argument)") }
        }
        print("")
        print("  Currently recorded in the manifest: \(manifest.requiredKernelArguments.count)")
        if manifest.requiredKernelArguments != detection.kernelArguments {
            print("  They differ. `multiemu-image traits \(identifier) --apply` writes the detected set.")
        }
        if arguments.contains("--apply") {
            try store.updateRequiredKernelArguments(
                detection.kernelArguments, layout: detection.partitionLayout, for: identifier)
            print("  Applied.")
        }
    } catch {
        fail("\(error)", code: 2)
    }

case "composite":
    guard let identifier = arguments.first else { fail("composite needs an image identifier.", code: 64) }
    arguments.removeFirst()
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    guard let outputPath = option("--out") else { fail("composite requires --out <disk.img>.", code: 64) }
    let userdataGiB = UInt64(option("--userdata-gib") ?? "32") ?? 32
    let slotSuffix = option("--slot-suffix") ?? AndroidCompositeLayout.defaultSlotSuffix
    let relaxVerifiedBoot = arguments.contains("--relax-verified-boot")

    do {
        let manifest = try store.manifest(for: identifier)
        let report = try store.verify(identifier)
        guard report.isIntact else {
            fail("Refusing to build a disk from an image that failed verification: \(report.problems.joined(separator: " "))", code: 2)
        }
        let partitions = AndroidCompositeLayout.partitions(
            manifest: manifest, store: store, slotSuffix: slotSuffix,
            userdataSizeBytes: userdataGiB * ByteCount.giB
        )
        print("Composite disk for \(identifier)")
        row("slot suffix", slotSuffix.isEmpty ? "(none)" : slotSuffix)
        row("partitions", "\(partitions.count)")
        if relaxVerifiedBoot {
            row("verified boot", "RELAXED — this disk's partitions are not verified")
        }
        print("")
        var builder = CompositeDiskBuilder()
        builder.relaxesVerifiedBoot = relaxVerifiedBoot
        let layout = try builder.build(
            partitions: partitions,
            to: URL(fileURLWithPath: outputPath),
            diskGUIDSeed: identifier,
            progress: { print("  \($0)") }
        )
        print("")
        print("  LBA map:")
        for partition in layout.partitions {
            print(String(format: "    %-18s %10llu .. %-10llu  %@",
                         (partition.name as NSString).utf8String!,
                         partition.firstLBA, partition.lastLBA,
                         ByteCount.describe(partition.sizeBytes)))
        }
        print("")
        row("disk", layout.diskURL.path)
        row("logical size", ByteCount.describe(layout.totalSizeBytes))
        if let allocated = try? layout.diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
            row("allocated on disk", ByteCount.describe(UInt64(allocated)))
        }
    } catch {
        fail("\(error)", code: 2)
    }

default:
    fail("Unknown command '\(command)'.\n\n\(help)", code: 64)
}
