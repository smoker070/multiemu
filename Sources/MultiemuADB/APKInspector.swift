import Foundation

/// Decides whether a file is an APK before anything is sent to a guest.
///
/// **Why check at all.** Milestone 10's criterion is that malformed input is
/// rejected with a named error, and the brief treats APK installation as a
/// security boundary. Handing an arbitrary host file to `pm install` because it
/// ends in `.apk` fails that on both counts: the extension is a claim by
/// whoever named the file, and a several-hundred-megabyte transfer that ends in
/// `INSTALL_PARSE_FAILED_NOT_APK` is a bad way to learn the file was a video.
///
/// **What it does not do.** It does not verify the signature, parse the binary
/// manifest, or decide whether the APK is safe to run. Android does all three,
/// and doing them badly here would be worse than not doing them. This answers
/// one question — is this a ZIP that contains an `AndroidManifest.xml` — which
/// is exactly the question that can be answered cheaply and correctly.
public enum APKInspector {

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case missing(String)
        case notAFile(String)
        case empty(String)
        case tooLarge(bytes: Int, limit: Int)
        case notAZipArchive(String)
        case noEndOfCentralDirectory(String)
        case noAndroidManifest(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case let .missing(path): return "There is no file at \(path)."
            case let .notAFile(path): return "\(path) is not a regular file."
            case let .empty(path): return "\(path) is empty."
            case let .tooLarge(bytes, limit):
                return "\(bytes) bytes is larger than the \(limit)-byte limit for an APK."
            case let .notAZipArchive(path):
                return "\(path) is not an APK: an APK is a ZIP archive and this does not begin like one."
            case let .noEndOfCentralDirectory(path):
                return "\(path) is not an APK: the ZIP central directory is missing or truncated."
            case let .noAndroidManifest(path):
                return "\(path) is not an APK: it is a ZIP archive with no AndroidManifest.xml."
            case let .unreadable(detail): return "Could not read the file: \(detail)"
            }
        }
    }

    /// A ceiling that exists to bound work, not to express a policy.
    ///
    /// Android's own limit is far higher; this stops a mistyped path from
    /// reading a disk image into memory before anything notices.
    public static let sizeLimit = 4 * 1024 * 1024 * 1024

    /// Every APK entry a manifest can be stored under.
    static let manifestName = "AndroidManifest.xml"

    public struct Description: Sendable, Equatable {
        public var byteCount: Int
        public var entryCount: Int
    }

    /// Reads enough of `url` to be sure it is an APK.
    ///
    /// The whole file is never read: the ZIP central directory is at the end,
    /// so this reads the tail, finds the directory, and walks the names.
    public static func inspect(_ url: URL) throws -> Description {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Failure.missing(url.path)
        }
        guard !isDirectory.boolValue else { throw Failure.notAFile(url.path) }

        let attributes: [FileAttributeKey: Any]
        do { attributes = try manager.attributesOfItem(atPath: url.path) }
        catch { throw Failure.unreadable(error.localizedDescription) }

        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw Failure.notAFile(url.path)
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw Failure.empty(url.path) }
        guard size <= sizeLimit else { throw Failure.tooLarge(bytes: size, limit: sizeLimit) }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw Failure.unreadable(error.localizedDescription) }
        defer { try? handle.close() }

        // A ZIP begins with a local file header, "PK\3\4". An empty archive
        // begins with the end-of-central-directory record instead; that is a
        // valid ZIP and never a valid APK, and it is rejected below for having
        // no manifest rather than here.
        let head = try read(handle, at: 0, count: 4)
        guard head.count == 4, head[0] == 0x50, head[1] == 0x4B else {
            throw Failure.notAZipArchive(url.path)
        }

        let entries = try entryNames(handle, fileSize: size, path: url.path)
        guard entries.names.contains(manifestName) else {
            throw Failure.noAndroidManifest(url.path)
        }
        return Description(byteCount: size, entryCount: entries.count)
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
    }

    /// Walks the central directory and returns the entry names.
    ///
    /// Only the names are needed, so each record is skipped by its own declared
    /// lengths rather than parsed.
    private static func entryNames(_ handle: FileHandle, fileSize: Int, path: String)
        throws -> (names: Set<String>, count: Int)
    {
        // The end-of-central-directory record is last, but a ZIP comment of up
        // to 65535 bytes may follow it, so it is searched for backwards.
        let tailLength = min(fileSize, 65_557)
        let tail = try read(handle, at: UInt64(fileSize - tailLength), count: tailLength)
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var recordOffset: Int?
        if tail.count >= 4 {
            for index in stride(from: tail.count - 4, through: 0, by: -1) {
                if tail[tail.startIndex + index] == signature[0],
                   tail[tail.startIndex + index + 1] == signature[1],
                   tail[tail.startIndex + index + 2] == signature[2],
                   tail[tail.startIndex + index + 3] == signature[3] {
                    recordOffset = index
                    break
                }
            }
        }
        guard let recordOffset, tail.count >= recordOffset + 22 else {
            throw Failure.noEndOfCentralDirectory(path)
        }

        let record = [UInt8](tail[tail.startIndex + recordOffset..<tail.endIndex])
        func value16(_ at: Int) -> Int { Int(record[at]) | Int(record[at + 1]) << 8 }
        func value32(_ at: Int) -> Int {
            Int(record[at]) | Int(record[at + 1]) << 8
                | Int(record[at + 2]) << 16 | Int(record[at + 3]) << 24
        }
        let entryCount = value16(10)
        let directorySize = value32(12)
        let directoryOffset = value32(16)
        guard directoryOffset >= 0, directorySize >= 0,
              directoryOffset + directorySize <= fileSize else {
            throw Failure.noEndOfCentralDirectory(path)
        }

        let directory = try read(handle, at: UInt64(directoryOffset), count: directorySize)
        var names = Set<String>()
        var cursor = 0
        let bytes = [UInt8](directory)
        // Each record: 46 fixed bytes, then name, extra field and comment.
        while cursor + 46 <= bytes.count {
            guard bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4B,
                  bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else { break }
            func local16(_ at: Int) -> Int {
                Int(bytes[cursor + at]) | Int(bytes[cursor + at + 1]) << 8
            }
            let nameLength = local16(28)
            let extraLength = local16(30)
            let commentLength = local16(32)
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { break }
            names.insert(String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return (names, entryCount)
    }
}
