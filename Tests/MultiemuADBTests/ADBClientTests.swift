import Foundation
import Testing
@testable import MultiemuADB

@Suite("The ADB client against a mock adbd", .serialized)
struct ADBClientTests {

    static func keyURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("multiemu-adb-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("adbkey")
    }

    @Test("A userdebug guest connects with no authentication and reports its banner")
    func connectsWithoutAuthentication() throws {
        let mock = try MockAdbd(authentication: .none)
        mock.start()
        defer { mock.stop() }

        let connection = ADBConnection(port: mock.port)
        defer { connection.close() }
        try connection.connect()
        #expect(connection.banner.hasPrefix("device::"))
        #expect(connection.banner.contains("shell_v2"))
    }

    @Test("A shell command's output is read to the end of the stream")
    func runsAShellCommand() throws {
        let mock = try MockAdbd()
        mock.shellResponses["getprop ro.build.version.release"] = "17\n"
        mock.start()
        defer { mock.stop() }

        let device = ADBDevice(port: mock.port)
        #expect(try device.shell("getprop ro.build.version.release") == "17\n")
        #expect(mock.shellCommands == ["getprop ro.build.version.release"])
    }

    @Test("A signed token gets the client connected")
    func authenticatesWithASignature() throws {
        let mock = try MockAdbd(authentication: .acceptsAnySignature)
        mock.start()
        defer { mock.stop() }

        let url = Self.keyURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let connection = ADBConnection(port: mock.port, key: try ADBKey.loadOrCreate(at: url))
        defer { connection.close() }
        try connection.connect()
        #expect(connection.banner.hasPrefix("device::"))
    }

    @Test("An unknown key is offered only after the signature is refused")
    func offersThePublicKeyOnlyOnASecondToken() throws {
        let mock = try MockAdbd(authentication: .demandsPublicKey)
        mock.start()
        defer { mock.stop() }

        let url = Self.keyURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = try ADBKey.loadOrCreate(at: url)
        let connection = ADBConnection(port: mock.port, key: key)
        defer { connection.close() }
        try connection.connect()

        #expect(connection.banner.hasPrefix("device::"))
        // Offering the key first would train a user to accept keys; it is only
        // sent once adbd has said the signature was not recognised.
        let offered = try #require(mock.receivedPublicKey)
        #expect(offered == (try key.androidPublicKeyBlob()))
    }

    @Test("A guest that never accepts anything produces a named failure, not a hang")
    func rejectedAuthenticationIsNamed() throws {
        let mock = try MockAdbd(authentication: .rejectsEverything)
        mock.start()
        defer { mock.stop() }

        let url = Self.keyURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let connection = ADBConnection(port: mock.port, key: try ADBKey.loadOrCreate(at: url))
        defer { connection.close() }
        #expect(throws: ADBConnection.Failure.self) { try connection.connect() }
    }

    @Test("A guest that demands authentication from a client with no key says so")
    func authenticationWithoutAKeyIsNamed() throws {
        let mock = try MockAdbd(authentication: .acceptsAnySignature)
        mock.start()
        defer { mock.stop() }

        let connection = ADBConnection(port: mock.port, key: nil)
        defer { connection.close() }
        #expect(throws: ADBConnection.Failure.self) { try connection.connect() }
    }

    @Test("A file survives a push and a pull unchanged, across several sync chunks")
    func pushAndPullRoundTrip() throws {
        let mock = try MockAdbd()
        mock.start()
        defer { mock.stop() }

        // Larger than one sync DATA message, so the chunking on the way out and
        // the reassembly on the way back are both exercised. A payload that
        // fits in one chunk would pass even if both were wrong.
        var payload = Data()
        for index in 0..<(ADBSync.dataChunkLimit * 2 + 1234) {
            payload.append(UInt8(index % 251))
        }

        let device = ADBDevice(port: mock.port)
        let sent = try device.push(payload, to: "/data/local/tmp/blob.bin")
        #expect(sent == payload.count)
        #expect(mock.file(at: "/data/local/tmp/blob.bin")?.data == payload)

        let returned = try device.pull("/data/local/tmp/blob.bin")
        #expect(returned == payload)
    }

    @Test("The mode travels with the file")
    func pushCarriesTheMode() throws {
        let mock = try MockAdbd()
        mock.start()
        defer { mock.stop() }

        let device = ADBDevice(port: mock.port)
        try device.push(Data("x".utf8), to: "/data/local/tmp/script.sh", mode: 0o755)
        #expect(mock.file(at: "/data/local/tmp/script.sh")?.mode == 0o755)
    }

    @Test("A relative guest path is refused before the connection is made")
    func relativeGuestPathIsRefused() throws {
        let mock = try MockAdbd()
        mock.start()
        defer { mock.stop() }

        let device = ADBDevice(port: mock.port)
        // adbd resolves a relative path against its own working directory,
        // which is neither what a caller means nor stable across versions.
        #expect(throws: ADBDevice.Failure.self) {
            try device.push(Data(), to: "tmp/relative")
        }
    }

    @Test("A refusal from the guest is reported with the guest's own words")
    func pushRefusalSurfacesTheReason() throws {
        let mock = try MockAdbd()
        mock.failNextPush = "Read-only file system"
        mock.start()
        defer { mock.stop() }

        let device = ADBDevice(port: mock.port)
        #expect(throws: ADBSync.Failure.self) {
            try device.push(Data("x".utf8), to: "/system/nope")
        }
    }

    @Test("Pulling a file the guest does not have is a named failure")
    func pullMissingFile() throws {
        let mock = try MockAdbd()
        mock.start()
        defer { mock.stop() }

        let device = ADBDevice(port: mock.port)
        #expect(throws: ADBSync.Failure.self) { try device.pull("/data/local/tmp/absent") }
    }

    @Test("A pull larger than the caller's limit is stopped rather than buffered")
    func pullRespectsItsSizeLimit() throws {
        let mock = try MockAdbd()
        mock.store(Data(repeating: 0x7F, count: 100_000), at: "/data/local/tmp/big.bin")
        mock.start()
        defer { mock.stop() }

        let device = ADBDevice(port: mock.port)
        #expect(throws: ADBSync.Failure.self) {
            try device.pull("/data/local/tmp/big.bin", sizeLimit: 1024)
        }
    }

    @Test("stat distinguishes a file that exists from one that does not")
    func statReportsExistence() throws {
        let mock = try MockAdbd()
        mock.store(Data("abc".utf8), at: "/data/local/tmp/there", mode: 0o644)
        mock.start()
        defer { mock.stop() }

        let device = ADBDevice(port: mock.port)
        let present = try device.stat("/data/local/tmp/there")
        #expect(present.exists)
        #expect(present.size == 3)
        // adbd answers a missing path with an all-zero STAT rather than a
        // failure, so "does it exist" has to be read from the mode.
        #expect(try device.stat("/data/local/tmp/absent").exists == false)
    }

    @Test("An APK is staged and installed, and the staged copy is removed")
    func installsAnAPK() throws {
        let mock = try MockAdbd()
        mock.defaultShellResponse = "Success\n"
        mock.start()
        defer { mock.stop() }

        let url = try APKInspectorTests.write(ZipFixture.apk(), named: "app.apk")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let device = ADBDevice(port: mock.port)
        let result = try device.install(apk: url)
        #expect(result.output.contains("Success"))
        #expect(result.packageBytes > 0)

        let installed = mock.shellCommands.filter { $0.hasPrefix("pm install -r /data/local/tmp/multiemu-") }
        #expect(installed.count == 1, "the package must be staged under /data/local/tmp")
        // A failed or successful install that leaves the package behind is a
        // surprise, and on persistent userdata a permanent one.
        #expect(mock.shellCommands.contains { $0.hasPrefix("rm -f /data/local/tmp/multiemu-") })
    }

    @Test("A refusal from pm is reported rather than read as success")
    func installFailureIsReported() throws {
        let mock = try MockAdbd()
        mock.defaultShellResponse = "Failure [INSTALL_FAILED_INVALID_APK]\n"
        mock.start()
        defer { mock.stop() }

        let url = try APKInspectorTests.write(ZipFixture.apk(), named: "app.apk")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let device = ADBDevice(port: mock.port)
        #expect(throws: ADBDevice.Failure.self) { try device.install(apk: url) }
        // Even a refused install must not leave the package in the guest.
        #expect(mock.shellCommands.contains { $0.hasPrefix("rm -f /data/local/tmp/multiemu-") })
    }

    @Test("A file that is not an APK never reaches the guest")
    func malformedPackageIsRejectedBeforeTransfer() throws {
        let mock = try MockAdbd()
        mock.defaultShellResponse = "Success\n"
        mock.start()
        defer { mock.stop() }

        let url = try APKInspectorTests.write(Data("not an archive".utf8), named: "bad.apk")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let device = ADBDevice(port: mock.port)
        #expect(throws: APKInspector.Failure.self) { try device.install(apk: url) }
        // The point of validating first: nothing was transferred and nothing
        // ran in the guest.
        #expect(mock.shellCommands.isEmpty)
    }

    @Test("A package name is matched exactly, not by substring")
    func installedCheckIsExact() throws {
        let mock = try MockAdbd()
        // `pm list packages foo` matches substrings, so the reply to a query
        // about com.example.app can legitimately include com.example.app.debug.
        mock.shellResponses["pm list packages com.example.app"] =
            "package:com.example.app.debug\n"
        mock.start()
        defer { mock.stop() }

        let device = ADBDevice(port: mock.port)
        #expect(try device.isInstalled("com.example.app") == false)
    }

    @Test("The foreground package is read out of dumpsys")
    func readsForegroundPackage() throws {
        let mock = try MockAdbd()
        mock.defaultShellResponse =
            "  topResumedActivity=ActivityRecord{a1b2c3 u0 com.android.deskclock/.DeskClock t42}\n"
        mock.start()
        defer { mock.stop() }

        let device = ADBDevice(port: mock.port)
        #expect(try device.foregroundPackage() == "com.android.deskclock")
    }
}
