import Foundation
import MultiemuSupport

/// Asks whether a disk image already has a writer, before a backend is spawned.
///
/// A QEMU that cannot take the write lock exits during its own startup, and
/// what reaches the user is raw engine stderr:
///
///     qemu-system-aarch64: -drive file=…/composite.qcow2,…: Failed to get
///     "write" lock | Is another process using the image …?
///
/// which is true, unactionable, and arrives next to whatever else the failure
/// path happened to collect. The condition is knowable one syscall earlier.
///
/// This matters because Multiemu can orphan its own backend: a QEMU child is
/// spawned with `posix_spawn` and macOS reparents it to launchd when the app
/// dies, so a crash or a force-quit leaves a process holding the lock with no
/// window attached. One was measured on a user's Mac holding a device's disk
/// for 44 hours; the device could not be started again until the process was
/// found by hand. `OrphanReaper` closes every exit that still runs our code,
/// and `BackendRunRecord` reclaims the leftover of a `SIGKILL`ed session on the
/// next launch. This check is the last line: it refuses to spawn onto a disk
/// somebody else holds, and names them, rather than letting QEMU fail raw.
public enum DiskImageLock {

    /// QEMU's own lock bytes, from `block/file-posix.c`:
    ///
    ///     #define RAW_LOCK_PERM_BASE    100
    ///     #define RAW_LOCK_SHARED_BASE  200
    ///     PERM_FOREACH(i) { int off = RAW_LOCK_PERM_BASE + i;
    ///                       uint64_t bit = (1ULL << i); … }
    ///
    /// `BLK_PERM_WRITE` is `0x02`, so `i == 1` and the two bytes that describe
    /// a writer are 101 (holds write permission) and 201 (does not share it).
    private static let writePermissionByte: off_t = 101
    private static let writeNotSharedByte: off_t = 201

    /// True when another process holds this image as a writer.
    ///
    /// Uses `F_OFD_GETLK`, which is the test QEMU itself performs
    /// (`qemu_lock_fd_test` in `util/osdep.c`) against the bytes QEMU itself
    /// locks — so it is true exactly when QEMU would refuse. It takes no lock
    /// and writes nothing; the descriptor is opened read-only.
    ///
    /// Verified on macOS 26.5 against a live `qemu-system-aarch64`: the bytes
    /// read `FREE` before it starts, `HELD` while it runs, and `FREE` again
    /// after it exits, and a second QEMU launched during the `HELD` window
    /// produced exactly the error quoted above.
    ///
    /// Returns `false` when the file cannot be opened at all — an unreadable
    /// image is a different fault, already reported by the readability check,
    /// and this must not turn it into a confusing second one.
    public static func hasWriter(at url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        for offset in [writePermissionByte, writeNotSharedByte] {
            var lock = flock()
            lock.l_whence = Int16(SEEK_SET)
            lock.l_start = offset
            lock.l_len = 1
            lock.l_type = Int16(F_WRLCK)
            // A failed query is not evidence of a lock. Filesystems that do not
            // implement OFD locks answer with an error, and refusing to start
            // on that would be worse than the problem being solved.
            guard fcntl(descriptor, F_OFD_GETLK, &lock) == 0 else { continue }
            if lock.l_type != Int16(F_UNLCK) { return true }
        }
        return false
    }

    /// A human description of whoever holds the image, for the failure message.
    ///
    /// Separate from `hasWriter` on purpose. Darwin reports `l_pid == -1` for
    /// an OFD lock — the lock belongs to an open file description, not to a
    /// process — so the syscall that *detects* the conflict cannot name it.
    /// `lsof` can, and runs only on the path that is already failing.
    ///
    /// Returns `nil` rather than guessing: a message that names no process is
    /// still better than one that names the wrong one.
    public static func holderDescription(of url: URL) -> String? {
        guard let pids = runTool("/usr/sbin/lsof", ["-t", "--", url.path]) else { return nil }
        let identifiers = pids
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        guard !identifiers.isEmpty else { return nil }

        let described = identifiers.map { pid -> String in
            // The name comes from the kernel, not from parsing `ps`. An earlier
            // version read `ps -o comm=`, which truncates to 16 characters — a
            // process running from /Applications/Xcode.app came back as
            // "/Applications/Xc", whose last path component is "Xc", and the
            // failure message duly told the user their disk was held by a
            // program called "Xc". A message that invents a name is worse than
            // one that gives only a pid.
            let name = BackendRunRecord.liveProcess(pid)?.name
            // `etime` is a single unambiguous field, so it is safe to read as
            // one; it is also the number that makes a leftover obvious.
            let elapsed = runTool("/bin/ps", ["-p", "\(pid)", "-o", "etime="])?
                .trimmingCharacters(in: .whitespaces)
            switch (name, elapsed) {
            case let (name?, elapsed?): return "\(name) (pid \(pid), running \(elapsed))"
            case let (name?, nil): return "\(name) (pid \(pid))"
            default: return "pid \(pid)"
            }
        }
        return described.isEmpty ? nil : described.joined(separator: ", ")
    }

    /// Runs a fixed tool with an argument array — never a shell, so a path with
    /// spaces or metacharacters cannot become a command.
    private static func runTool(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
