import CryptoKit
import Foundation
import MultiemuBackend
import MultiemuSupport

/// Manages installed Android image sets on disk.
///
/// Three guarantees, in priority order:
///
/// 1. **Nothing boots unverified.** A guest image is a kernel that runs with
///    full guest privileges. SHA-256 is checked on install and again before
///    every boot, and a mismatch is a hard failure, never a warning.
/// 2. **Read-only partitions are shared, not copied.** One `system.img` serves
///    every device using that image.
/// 3. **Unpacking is idempotent.** Re-running it produces identical outputs, so
///    a partially completed install can simply be repeated.
public struct ImageStore: Sendable {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case imageNotInstalled(String)
        case missingFile(role: PartitionRole, path: String)
        case checksumMismatch(path: String, expected: String, actual: String)
        case sizeMismatch(path: String, expected: UInt64, actual: UInt64)
        case manifestInvalid([String])
        case unpackFailed(String)

        public var description: String {
            switch self {
            case let .imageNotInstalled(identifier):
                return "No installed image with identifier \"\(identifier)\"."
            case let .missingFile(role, path):
                return "The \(role.rawValue) file is missing at \(path)."
            case let .checksumMismatch(path, expected, actual):
                return """
                    Integrity check failed for \(path). Expected SHA-256 \(expected), found \(actual). \
                    The image is corrupt or has been modified; it will not be booted.
                    """
            case let .sizeMismatch(path, expected, actual):
                return "\(path) is \(actual) bytes; the manifest records \(expected)."
            case let .manifestInvalid(problems):
                return "The image manifest is not usable: \(problems.joined(separator: " "))"
            case let .unpackFailed(detail):
                return "Could not unpack the image: \(detail)"
            }
        }
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Multiemu", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
    }

    public func directory(for imageIdentifier: String) -> URL {
        root.appendingPathComponent(imageIdentifier, isDirectory: true)
    }

    public func manifestURL(for imageIdentifier: String) -> URL {
        directory(for: imageIdentifier).appendingPathComponent("manifest.json")
    }

    // MARK: - Reading

    public func installedImageIdentifiers() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .map(\.lastPathComponent)
            .sorted()
    }

    public func manifest(for imageIdentifier: String) throws -> ImageManifest {
        let url = manifestURL(for: imageIdentifier)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw Failure.imageNotInstalled(imageIdentifier)
        }
        return try JSONDecoder().decode(ImageManifest.self, from: data)
    }

    /// Replaces an installed image's required kernel arguments.
    ///
    /// Separate from installing because the arguments can only be *detected*
    /// once the image is unpacked, and unpacking needs an installed image. The
    /// file list and its hashes are untouched, so `verify` is unaffected — the
    /// manifest describes the image, and this is the part of the description
    /// the image itself can answer.
    @discardableResult
    public func updateRequiredKernelArguments(
        _ arguments: [String], layout: AndroidGuestPlan.PartitionLayout? = nil,
        for imageIdentifier: String
    ) throws -> ImageManifest {
        var manifest = try manifest(for: imageIdentifier)
        manifest.requiredKernelArguments = arguments
        if let layout { manifest.partitionLayout = layout }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(for: imageIdentifier), options: .atomic)
        return manifest
    }

    public func url(of file: ManifestFile, in imageIdentifier: String) -> URL {
        directory(for: imageIdentifier).appendingPathComponent(file.relativePath)
    }

    // MARK: - Verification

    public struct VerificationReport: Sendable, Equatable {
        public var imageIdentifier: String
        public var checkedFiles: Int
        public var problems: [String]
        public var isIntact: Bool { problems.isEmpty }
    }

    /// Verifies every file against the manifest.
    ///
    /// Run on install, before every boot, and from diagnostics. Derived files
    /// (kernel, ramdisks) are skipped when absent, because they are regenerated
    /// by unpacking rather than shipped.
    public func verify(_ imageIdentifier: String) throws -> VerificationReport {
        let manifest = try manifest(for: imageIdentifier)
        let structural = manifest.structuralProblems()
        guard structural.isEmpty else { throw Failure.manifestInvalid(structural) }

        var problems: [String] = []
        var checked = 0

        for file in manifest.files {
            let fileURL = url(of: file, in: imageIdentifier)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                if file.role.isDerived { continue }   // regenerated by unpacking
                problems.append(Failure.missingFile(role: file.role, path: fileURL.path).description)
                continue
            }
            do {
                try verifyFile(file, at: fileURL)
                checked += 1
            } catch {
                problems.append(String(describing: error))
            }
        }

        return VerificationReport(
            imageIdentifier: imageIdentifier,
            checkedFiles: checked,
            problems: problems
        )
    }

    private func verifyFile(_ file: ManifestFile, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard actualSize == file.sizeBytes else {
            throw Failure.sizeMismatch(path: url.path, expected: file.sizeBytes, actual: actualSize)
        }
        let actualDigest = try Self.sha256(ofFileAt: url)
        guard actualDigest == file.sha256.lowercased() else {
            throw Failure.checksumMismatch(path: url.path, expected: file.sha256, actual: actualDigest)
        }
    }

    /// Streaming SHA-256, so a 4 GiB `super.img` does not need 4 GiB of RAM.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Unpacking

    public struct UnpackResult: Sendable, Equatable {
        public var kernelURL: URL
        public var ramdiskURL: URL?
        public var deviceTreeURL: URL?
        public var bootImageCommandLine: String
        public var vendorBootCommandLine: String?
        public var detectedHeaderVersion: UInt32
    }

    /// Splits `boot.img` and `vendor_boot.img` into direct-kernel-boot inputs.
    ///
    /// Ramdisk ordering: the vendor ramdisk is written first, then the generic
    /// ramdisk. Linux extracts concatenated cpio archives in order with later
    /// entries winning, so this is the order that lets the generic ramdisk
    /// override vendor files. See `docs/VERIFY.md` → `RAMDISK-CONCAT-ORDER`;
    /// this is the documented AOSP order but has not yet been confirmed against
    /// a booting image, and it is a one-line change if it proves reversed.
    @discardableResult
    public func unpackBootImages(for imageIdentifier: String) throws -> UnpackResult {
        let manifest = try manifest(for: imageIdentifier)
        let directory = self.directory(for: imageIdentifier)
        let derived = directory.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)

        guard let bootImageFile = manifest.file(for: .bootImage) else {
            throw Failure.unpackFailed("The manifest has no boot image to unpack.")
        }
        let bootImageURL = url(of: bootImageFile, in: imageIdentifier)
        guard let bootData = FileManager.default.contents(atPath: bootImageURL.path) else {
            throw Failure.missingFile(role: .bootImage, path: bootImageURL.path)
        }

        let boot: AndroidBootImage.BootImage
        do {
            boot = try AndroidBootImage.parseBootImage(bootData)
        } catch {
            throw Failure.unpackFailed(String(describing: error))
        }

        // A boot image without a kernel is not something to unpack a kernel
        // from; init_boot.img is exactly that, and is handled separately below.
        guard let kernelRange = boot.kernelRange else {
            throw Failure.unpackFailed(
                "\(bootImageFile.relativePath) contains no kernel, so there is nothing to boot.")
        }
        let kernelURL = derived.appendingPathComponent("kernel")
        try bootData[kernelRange].write(to: kernelURL, options: .atomic)

        var ramdiskParts: [Data] = []
        var vendorCommandLine: String?

        if let vendorFile = manifest.file(for: .vendorBootImage),
           let vendorData = FileManager.default.contents(atPath: url(of: vendorFile, in: imageIdentifier).path) {
            let vendorBoot: AndroidBootImage.VendorBootImage
            do {
                vendorBoot = try AndroidBootImage.parseVendorBootImage(vendorData)
            } catch {
                throw Failure.unpackFailed(String(describing: error))
            }
            ramdiskParts.append(vendorData[vendorBoot.vendorRamdiskRange])
            vendorCommandLine = vendorBoot.kernelCommandLine
            if let dtbRange = vendorBoot.dtbRange {
                let dtbURL = derived.appendingPathComponent("dtb")
                try vendorData[dtbRange].write(to: dtbURL, options: .atomic)
            }
        }

        // The generic ramdisk, which carries /init.
        //
        // Before Android 13 it lived in boot.img; from 13 onward it has its own
        // init_boot.img and boot.img carries only a kernel. Taking it from
        // boot.img alone leaves an initramfs of vendor files with no init, so
        // the guest cannot start userspace at all.
        //
        // Appended AFTER the vendor ramdisk: the kernel unpacks concatenated
        // cpio archives in order and later entries win, which is how the
        // generic ramdisk is meant to sit on top.
        if let ramdiskRange = boot.ramdiskRange {
            ramdiskParts.append(bootData[ramdiskRange])
        } else if let genericFile = manifest.file(for: .ramdisk),
                  let genericData = FileManager.default.contents(
                      atPath: url(of: genericFile, in: imageIdentifier).path) {
            // init_boot.img has no kernel by design.
            let generic = try {
                do {
                    return try AndroidBootImage.parseBootImage(genericData, requiresKernel: false)
                } catch {
                    throw Failure.unpackFailed(
                        "init_boot.img could not be parsed: \(error)")
                }
            }()
            guard let genericRange = generic.ramdiskRange else {
                throw Failure.unpackFailed(
                    "init_boot.img contains no ramdisk, so the guest would have no init.")
            }
            ramdiskParts.append(genericData[genericRange])
        }

        var ramdiskURL: URL?
        if !ramdiskParts.isEmpty {
            let combined = derived.appendingPathComponent("ramdisk")
            var combinedData = Data()
            for part in ramdiskParts { combinedData.append(part) }
            try combinedData.write(to: combined, options: .atomic)
            ramdiskURL = combined
        }

        let dtbURL = derived.appendingPathComponent("dtb")
        return UnpackResult(
            kernelURL: kernelURL,
            ramdiskURL: ramdiskURL,
            deviceTreeURL: FileManager.default.fileExists(atPath: dtbURL.path) ? dtbURL : nil,
            bootImageCommandLine: boot.kernelCommandLine,
            vendorBootCommandLine: vendorCommandLine,
            detectedHeaderVersion: boot.headerVersion
        )
    }
}
