import Darwin
import Foundation
import MultiemuSupport

/// Kills backend processes that would otherwise outlive this one.
///
/// QEMU is spawned with `posix_spawn` by way of `Process`, and macOS has no
/// equivalent of Linux's `PR_SET_PDEATHSIG`: when the parent dies the child is
/// reparented to launchd and keeps running. Nothing reaps it. A device's qcow2
/// carries an exclusive write lock, so the leftover process makes that device
/// permanently unstartable — one was found on a user's Mac holding a disk for
/// 44 hours with no window attached, burning four vCPUs, and the emulator could
/// not be launched again until the process was found by hand with `lsof`.
///
/// The project had already reasoned this out for its command-line harnesses —
/// `RunDeadline.killGuest` says "an early `exit()` from the harness leaves QEMU
/// orphaned and still spinning its vCPUs" — and every spike calls `kill()` on
/// every exit path. The application, the one binary users actually run, was the
/// only thing in the repository without it.
///
/// ## What this can and cannot cover
///
/// | How the app ends | Covered | By what |
/// | --- | --- | --- |
/// | Quit, Cmd-Q, window closed | yes | `AppDelegate` stops devices gracefully |
/// | `exit()` from anywhere | yes | `atexit` |
/// | `SIGTERM`/`SIGINT`/`SIGHUP` (logout, Ctrl-C) | yes | handler below |
/// | `SIGKILL`, kernel panic, power loss | **no** | nothing can run in-process |
///
/// The last row is why `DiskImageLock` exists: what cannot be prevented has to
/// be *detected*, so the next launch explains itself instead of failing raw.
public enum OrphanReaper {

    /// Registered pids live in a preallocated C array rather than a Swift
    /// collection because the signal handler reads them. Allocating, locking or
    /// touching Swift runtime metadata inside a signal handler is undefined;
    /// `kill(2)` and a load from a fixed buffer are async-signal-safe.
    private static let capacity = 32
    private nonisolated(unsafe) static let slots: UnsafeMutablePointer<pid_t> = {
        let buffer = UnsafeMutablePointer<pid_t>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        return buffer
    }()

    private static let lock = NSLock()
    private nonisolated(unsafe) static var installed = false

    /// Starts reaping `pid` if this process ends before it does.
    public static func adopt(_ pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        installHandlersIfNeeded()
        for index in 0..<capacity where slots[index] == 0 {
            slots[index] = pid
            return
        }
        // A full table means more than 32 concurrent backends, which is far
        // past anything this application supports. Say so rather than silently
        // failing to protect the newest one.
        MultiemuLog.backend.error(
            "Orphan reaper is full; pid \(pid, privacy: .public) will not be cleaned up on exit")
    }

    /// Stops tracking a process that has already exited or been stopped
    /// deliberately, so its pid cannot be signalled after being recycled.
    public static func release(_ pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        for index in 0..<capacity where slots[index] == pid { slots[index] = 0 }
    }

    /// Everything currently adopted. For tests and diagnostics.
    public static var adopted: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<capacity).map { slots[$0] }.filter { $0 != 0 }
    }

    /// Kills every adopted process. Safe to call from a signal handler: it does
    /// nothing but read the buffer and call `kill(2)`.
    private static func reapAll() {
        for index in 0..<capacity {
            let pid = slots[index]
            if pid != 0 { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    private static func installHandlersIfNeeded() {
        guard !installed else { return }
        installed = true

        atexit { OrphanReaper.reapAll() }

        // `SA_RESETHAND` restores the default action before the handler runs,
        // so re-raising produces the normal termination the caller expected —
        // a Ctrl-C still reads as a Ctrl-C, and the exit status is unchanged.
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { number in
                OrphanReaper.reapAll()
                raise(number)
            }
            action.sa_flags = Int32(SA_RESETHAND)
            sigemptyset(&action.sa_mask)
            sigaction(signalNumber, &action, nil)
        }
    }
}
