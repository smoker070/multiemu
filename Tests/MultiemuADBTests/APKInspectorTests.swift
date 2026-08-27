import Foundation
import Testing
@testable import MultiemuADB

@Suite("Rejecting things that are not APKs")
struct APKInspectorTests {

    static func write(_ data: Data, named name: String = "fixture.apk") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiemu-apk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("A ZIP containing AndroidManifest.xml is accepted")
    func acceptsAnAPK() throws {
        let url = try Self.write(ZipFixture.apk())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let description = try APKInspector.inspect(url)
        #expect(description.entryCount == 2)
        #expect(description.byteCount > 0)
    }

    @Test("A ZIP with no manifest is refused, whatever it is called")
    func refusesAZipWithNoManifest() throws {
        let data = ZipFixture.archive(entries: [(name: "notes.txt", contents: Data("hi".utf8))])
        let url = try Self.write(data, named: "looks-like.apk")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // The extension is a claim by whoever named the file; the contents are
        // the evidence.
        #expect(throws: APKInspector.Failure.noAndroidManifest(url.path)) {
            try APKInspector.inspect(url)
        }
    }

    @Test("A file that is not a ZIP at all is refused before anything is sent")
    func refusesNonZip() throws {
        let url = try Self.write(Data("#!/bin/sh\necho hello\n".utf8), named: "payload.apk")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: APKInspector.Failure.notAZipArchive(url.path)) {
            try APKInspector.inspect(url)
        }
    }

    @Test("An empty file is refused with its own error, not a parse failure")
    func refusesEmpty() throws {
        let url = try Self.write(Data(), named: "empty.apk")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: APKInspector.Failure.empty(url.path)) { try APKInspector.inspect(url) }
    }

    @Test("A missing path is refused")
    func refusesMissing() {
        let url = URL(fileURLWithPath: "/tmp/multiemu-does-not-exist-\(UUID().uuidString).apk")
        #expect(throws: APKInspector.Failure.missing(url.path)) { try APKInspector.inspect(url) }
    }

    @Test("A directory is refused rather than read")
    func refusesDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiemu-dir-\(UUID().uuidString).apk", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: APKInspector.Failure.notAFile(directory.path)) {
            try APKInspector.inspect(directory)
        }
    }

    @Test("A ZIP whose central directory has been cut off is refused")
    func refusesTruncatedArchive() throws {
        var data = ZipFixture.apk()
        // Keep the local headers, lose the directory the names live in. A
        // truncated download looks exactly like this.
        data = data.prefix(data.count / 2)
        let url = try Self.write(Data(data), named: "truncated.apk")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: APKInspector.Failure.noEndOfCentralDirectory(url.path)) {
            try APKInspector.inspect(url)
        }
    }

    @Test("An archive with a trailing comment is still read")
    func handlesTrailingComment() throws {
        // The end-of-central-directory record is not always the last bytes of
        // the file; a comment may follow it, which is why it is searched for
        // backwards rather than read at a fixed offset.
        var data = ZipFixture.apk()
        let commentLength = 300
        // Rewrite the comment length field, then append the comment.
        let lengthOffset = data.count - 2
        data[lengthOffset] = UInt8(commentLength & 0xFF)
        data[lengthOffset + 1] = UInt8((commentLength >> 8) & 0xFF)
        data.append(Data(repeating: 0x41, count: commentLength))

        let url = try Self.write(data, named: "commented.apk")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try APKInspector.inspect(url).entryCount == 2)
    }
}
