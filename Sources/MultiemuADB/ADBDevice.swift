import Foundation

/// What the rest of the product uses to talk to a guest over ADB.
///
/// One connection per operation. ADB multiplexes streams and this client does
/// not (see `ADBConnection`), so holding a connection open across calls would
/// serialise unrelated work behind whatever is running; opening one costs a
/// loopback `connect` and a handshake, which is cheap next to anything worth
/// doing over it.
///
/// Every call blocks. Callers must run them off the cooperative thread pool.
public struct ADBDevice: Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case installRefused(reason: String)
        case commandFailed(command: String, output: String)
        case pathNotAbsolute(String)

        public var description: String {
            switch self {
            case let .installRefused(reason):
                return "The guest refused to install the package: \(reason)"
            case let .commandFailed(command, output):
                return "`\(command)` failed in the guest: \(output)"
            case let .pathNotAbsolute(path):
                return "A guest path must be absolute; got `\(path)`."
            }
        }
    }

    public let host: String
    public let port: Int
    public let keyURL: URL?
    public let timeout: TimeInterval

    /// Where an installer stages a file inside the guest.
    ///
    /// `pm install` cannot read `/system` or any other read-only mount — it
    /// answers `Error: Unable to open file … Consider using a file under
    /// /data/local/tmp/`, which is why the push happens first rather than the
    /// installer being pointed at a path the guest can already see.
    public static let stagingDirectory = "/data/local/tmp"

    public init(host: String = "127.0.0.1", port: Int, keyURL: URL? = nil,
                timeout: TimeInterval = 60) {
        self.host = host
        self.port = port
        self.keyURL = keyURL
        self.timeout = timeout
    }

    public func withConnection<T>(_ body: (ADBConnection) throws -> T) throws -> T {
        let key = try keyURL.map { try ADBKey.loadOrCreate(at: $0) }
        let connection = ADBConnection(host: host, port: port, key: key, timeout: timeout)
        defer { connection.close() }
        try connection.connect()
        return try body(connection)
    }

    /// The banner adbd answers `CNXN` with — the device's identity.
    public func identify() throws -> String {
        try withConnection { $0.banner }
    }

    @discardableResult
    public func shell(_ command: String) throws -> String {
        try withConnection { connection in
            try connection.openStream(service: "shell:" + command)
            return String(decoding: try connection.readToEnd(), as: UTF8.self)
        }
    }

    // MARK: - Files

    /// Sends bytes to a guest path.
    ///
    /// The guest path is required to be absolute. A relative path is resolved
    /// against adbd's working directory, which is not a place a caller means to
    /// write to and not a place that stays the same between Android versions.
    @discardableResult
    public func push(_ data: Data, to remotePath: String, mode: UInt32 = 0o644) throws -> Int {
        guard remotePath.hasPrefix("/") else { throw Failure.pathNotAbsolute(remotePath) }
        return try withConnection { connection in
            let sync = ADBSync(connection: connection)
            try sync.begin()
            defer { sync.end() }
            return try sync.push(data: data, to: remotePath, mode: mode)
        }
    }

    @discardableResult
    public func push(contentsOf url: URL, to remotePath: String, mode: UInt32 = 0o644) throws -> Int {
        try push(try Data(contentsOf: url), to: remotePath, mode: mode)
    }

    public func pull(_ remotePath: String, sizeLimit: Int = 256 * 1024 * 1024) throws -> Data {
        guard remotePath.hasPrefix("/") else { throw Failure.pathNotAbsolute(remotePath) }
        return try withConnection { connection in
            let sync = ADBSync(connection: connection)
            try sync.begin()
            defer { sync.end() }
            return try sync.pull(remotePath, sizeLimit: sizeLimit)
        }
    }

    public func stat(_ remotePath: String) throws -> ADBSync.Entry {
        try withConnection { connection in
            let sync = ADBSync(connection: connection)
            try sync.begin()
            defer { sync.end() }
            return try sync.stat(remotePath)
        }
    }

    // MARK: - Packages

    public struct InstallResult: Sendable, Equatable {
        public var packageBytes: Int
        public var pushSeconds: Double
        public var installSeconds: Double
        /// What `pm` printed, kept verbatim for a report.
        public var output: String

        public var totalSeconds: Double { pushSeconds + installSeconds }
        /// Push rate in MiB/s, which is the half that scales with size.
        public var pushMebibytesPerSecond: Double {
            pushSeconds > 0 ? Double(packageBytes) / 1_048_576 / pushSeconds : 0
        }
    }

    /// Validates an APK, stages it in the guest, installs it, and cleans up.
    ///
    /// `-r` is passed because reinstalling is the common case for a developer
    /// and refusing it would make the feature useless on the second run.
    public func install(apk url: URL, replacingExisting: Bool = true) throws -> InstallResult {
        let description = try APKInspector.inspect(url)
        let data = try Data(contentsOf: url)
        let remote = "\(Self.stagingDirectory)/multiemu-\(UUID().uuidString).apk"

        let pushStart = ContinuousClock.now
        try push(data, to: remote, mode: 0o644)
        let pushSeconds = ContinuousClock.now.durationSince(pushStart)

        // The staged file is removed whatever happens next: a failed install
        // that leaves a copy of the package in the guest is a surprise, and on
        // a persistent userdata image it is a permanent one.
        defer { _ = try? shell("rm -f \(remote)") }

        let installStart = ContinuousClock.now
        let flags = replacingExisting ? "-r " : ""
        let output = try shell("pm install \(flags)\(remote)")
        let installSeconds = ContinuousClock.now.durationSince(installStart)

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("Success") else {
            throw Failure.installRefused(reason: trimmed.isEmpty ? "pm printed nothing" : trimmed)
        }
        return InstallResult(packageBytes: description.byteCount,
                             pushSeconds: pushSeconds,
                             installSeconds: installSeconds,
                             output: trimmed)
    }

    /// Is the package installed for the current user?
    public func isInstalled(_ packageName: String) throws -> Bool {
        let listing = try shell("pm list packages \(packageName)")
        // `pm list packages foo` matches by substring, so an exact line is
        // required: asking about `com.example.app` must not be answered by
        // `com.example.app.debug`.
        return listing.split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces) == "package:\(packageName)"
        }
    }

    /// Does the package have a launcher entry the user could tap?
    public func hasLauncherActivity(_ packageName: String) throws -> Bool {
        let output = try shell(
            "cmd package query-activities --brief -a android.intent.action.MAIN "
            + "-c android.intent.category.LAUNCHER")
        return output.contains(packageName + "/")
    }

    /// Starts the package's launcher activity and reports what `am` said.
    @discardableResult
    public func launch(_ packageName: String) throws -> String {
        let output = try shell(
            "monkey -p \(packageName) -c android.intent.category.LAUNCHER 1")
        guard !output.contains("No activities found") else {
            throw Failure.commandFailed(command: "monkey -p \(packageName)", output: output)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The package currently on top, as `dumpsys activity` reports it.
    public func foregroundPackage() throws -> String? {
        let output = try shell("dumpsys activity activities | grep -m1 topResumedActivity")
        // "topResumedActivity=ActivityRecord{… u0 com.example/.Main t123}"
        guard let range = output.range(of: "u0 ") else { return nil }
        let rest = output[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return String(rest[rest.startIndex..<slash])
    }

    @discardableResult
    public func uninstall(_ packageName: String, forCurrentUserOnly: Bool = true) throws -> String {
        let scope = forCurrentUserOnly ? "--user 0 " : ""
        return try shell("pm uninstall \(scope)\(packageName)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension ContinuousClock.Instant {
    func durationSince(_ other: ContinuousClock.Instant) -> Double {
        let duration = other.duration(to: self)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
