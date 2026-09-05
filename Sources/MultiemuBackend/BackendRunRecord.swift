import Darwin
import Foundation
import MultiemuSupport

/// A note on disk saying "this device has a backend running, and here is how to
/// recognise it".
///
/// `OrphanReaper` covers every way this process can end *while still running
/// code* — quit, `exit()`, `SIGTERM`. It cannot cover `SIGKILL`, a kernel panic
/// or a power cut, because nothing of ours runs. What is left behind is a QEMU
/// holding a device's qcow2 write lock, and the device stays unstartable until
/// somebody finds the process by hand. One was measured at 44 hours.
///
/// So what cannot be prevented is made **recoverable**: the record is written
/// when a backend starts and removed when it exits, and the next launch uses it
/// to recognise its own leftover and clear it.
///
/// ## Why a pid alone is not enough
///
/// Killing by a pid read from a file is how unrelated processes get killed.
/// Pids are recycled, and a stale record can name a pid that now belongs to a
/// user's editor. `kill(pid, 0)` only says *something* is alive there.
///
/// The record therefore stores the process's **start time**, which the kernel
/// reports to microsecond precision (`kp_proc.p_starttime` via
/// `KERN_PROC_PID`). A recycled pid cannot have the same start time as the
/// process that previously held it, so an exact match is proof of identity.
/// `p_comm` is checked too, so a record corrupted into naming an unrelated
/// live process still cannot authorise a signal.
///
/// Every one of those gates must pass before anything is signalled. If any
/// fails, the record is treated as stale — deleted, never acted on.
public struct BackendRunRecord: Codable, Sendable, Equatable {

    public var processIdentifier: Int32
    /// `kp_proc.p_starttime`, split so it survives JSON without precision loss.
    public var startedAtSeconds: Int64
    public var startedAtMicroseconds: Int32
    /// The launched binary. For the human-readable message only.
    public var executablePath: String
    /// `p_comm` as the kernel reported it **at launch**, compared exactly.
    ///
    /// Deliberately not derived from `executablePath`. `p_comm` names what is
    /// actually running, which need not share the basename of what was
    /// launched: `/usr/bin/python3` re-execs as `Python`, and the kernel
    /// truncates to `MAXCOMLEN` (16), so `qemu-system-aarch64` appears as
    /// `qemu-system-aarc`. Inferring the name got both wrong; recording what
    /// the kernel actually said makes the comparison exact.
    public var processName: String
    /// Recorded for the human-readable message only.
    public var recordedAt: Date

    public init(
        processIdentifier: Int32,
        startedAtSeconds: Int64,
        startedAtMicroseconds: Int32,
        executablePath: String,
        processName: String,
        recordedAt: Date = Date()
    ) {
        self.processIdentifier = processIdentifier
        self.startedAtSeconds = startedAtSeconds
        self.startedAtMicroseconds = startedAtMicroseconds
        self.executablePath = executablePath
        self.processName = processName
        self.recordedAt = recordedAt
    }

    // MARK: - Where it lives

    /// Beside the disk it protects. That is the device directory in practice,
    /// and it needs no new configuration to reach — the resource being guarded
    /// and the note guarding it stay together, so deleting a device removes
    /// both.
    public static func url(besideDisk disk: URL) -> URL {
        disk.deletingLastPathComponent().appendingPathComponent("backend-run.json")
    }

    // MARK: - Reading the process table

    /// The kernel's start time and short name for a pid, or `nil` if no such
    /// process exists.
    public static func liveProcess(_ pid: Int32) -> (seconds: Int64, microseconds: Int32, name: String)? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_starttime
        let name = withUnsafePointer(to: info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return (Int64(started.tv_sec), Int32(started.tv_usec), name)
    }

    // MARK: - Writing and clearing

    public static func write(_ record: BackendRunRecord, besideDisk disk: URL) {
        let target = url(besideDisk: disk)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: target, options: .atomic)
        } catch {
            // Not fatal: without the record the next launch still *detects* the
            // held disk via `DiskImageLock`, it just cannot clear it by itself.
            MultiemuLog.backend.error(
                "Could not write the backend run record: \(String(describing: error), privacy: .public)")
        }
    }

    public static func read(besideDisk disk: URL) -> BackendRunRecord? {
        let source = url(besideDisk: disk)
        guard let data = try? Data(contentsOf: source) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackendRunRecord.self, from: data)
    }

    public static func clear(besideDisk disk: URL) {
        try? FileManager.default.removeItem(at: url(besideDisk: disk))
    }

    // MARK: - Proving identity

    /// True only when the recorded process is still alive **and provably the
    /// same one** — same pid, same start time to the microsecond, same short
    /// name. Anything less is a stale record naming somebody else's process.
    public var namesALiveBackend: Bool {
        // Never signal ourselves, whatever the record says.
        guard processIdentifier > 0, processIdentifier != getpid() else { return false }
        guard let live = Self.liveProcess(processIdentifier) else { return false }
        guard live.seconds == startedAtSeconds,
              live.microseconds == startedAtMicroseconds else { return false }
        return live.name == processName
    }

    // MARK: - Reclaiming

    public enum Reclamation: Equatable, Sendable {
        /// No record, or it named nothing that is still alive. Nothing to do.
        case nothingToReclaim
        /// A record named a live process, but it could not be proven to be the
        /// backend we recorded. **Nothing was signalled.**
        case refusedToActOnAStaleRecord
        case stoppedGracefully(pid: Int32)
        case killed(pid: Int32)
        case couldNotStop(pid: Int32)
    }

    /// Stops the recorded backend, if and only if it can be proven to be ours.
    ///
    /// `SIGTERM` first so QEMU closes its qcow2 properly, escalating to
    /// `SIGKILL` only if it will not go. Called on the path where the user has
    /// just asked to start this very device, so clearing its leftover backend
    /// is the action they are asking for.
    public static func reclaim(
        besideDisk disk: URL,
        gracePeriod: Duration = .seconds(5)
    ) async -> Reclamation {
        guard let record = read(besideDisk: disk) else { return .nothingToReclaim }

        guard record.namesALiveBackend else {
            // The pid may now belong to something else entirely. Delete the
            // note; never act on it.
            clear(besideDisk: disk)
            return Self.liveProcess(record.processIdentifier) == nil
                ? .nothingToReclaim
                : .refusedToActOnAStaleRecord
        }

        let pid = record.processIdentifier
        MultiemuLog.backend.info("""
            Reclaiming a backend left over from an earlier session: \
            pid \(pid, privacy: .public), \((record.executablePath as NSString).lastPathComponent, privacy: .public)
            """)

        _ = Darwin.kill(pid, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while ContinuousClock.now < deadline {
            // Re-prove identity each time: if it exits and the pid is recycled
            // mid-wait, this stops looking at the newcomer.
            guard record.namesALiveBackend else {
                clear(besideDisk: disk)
                return .stoppedGracefully(pid: pid)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard record.namesALiveBackend else {
            clear(besideDisk: disk)
            return .stoppedGracefully(pid: pid)
        }
        _ = Darwin.kill(pid, SIGKILL)
        try? await Task.sleep(for: .milliseconds(300))
        let stopped = !record.namesALiveBackend
        if stopped { clear(besideDisk: disk) }
        return stopped ? .killed(pid: pid) : .couldNotStop(pid: pid)
    }
}
