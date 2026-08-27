import Foundation
import MultiemuSupport

/// A recognised point in a guest's boot.
public struct BootMilestone: Sendable, Equatable {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        // Generic Linux
        case kernelStarted
        case kernelMemoryFreed
        case initStarted
        case initramfsShell
        case userspaceReady
        case loginPrompt
        // Android
        case androidInitStarted
        case androidSecondStage
        case androidZygoteStarted
        case androidBootAnimationFinished
        case androidBootCompleted
        // Failures
        case kernelPanic
        case rootMountFailure

        /// A milestone that ends the boot successfully.
        ///
        /// `initramfsShell` counts: the kernel booted and userspace ran. It is a
        /// separate case from `userspaceReady` so that a boot which never
        /// reached the real root filesystem is never reported as one that did.
        public var isTerminalSuccess: Bool {
            switch self {
            case .userspaceReady, .loginPrompt, .androidBootCompleted, .initramfsShell: return true
            default: return false
            }
        }

        /// A milestone that ends the boot in failure.
        public var isTerminalFailure: Bool {
            switch self {
            case .kernelPanic, .rootMountFailure: return true
            default: return false
            }
        }
    }

    public var kind: Kind
    public var matchedLine: String
    public var elapsed: Duration

    public init(kind: Kind, matchedLine: String, elapsed: Duration) {
        self.kind = kind
        self.matchedLine = matchedLine
        self.elapsed = elapsed
    }
}

/// Recognises boot milestones in a guest serial console stream and timestamps them.
///
/// This is the instrument behind the cold-boot and first-boot metrics. It is a
/// pure state machine over lines of text, so it is fully testable against
/// recorded console transcripts without booting anything — which matters,
/// because the alternative is a timing measurement nobody can regression-test.
///
/// Matching is substring-based and case-sensitive. Kernel and Android messages
/// are stable, well-known strings; loosening to case-insensitive matching
/// produced false positives on Android's own log lines during development of
/// this probe.
public struct GuestBootProbe: Sendable {

    /// Ordered longest-prefix-first so more specific patterns win.
    private static let patterns: [(BootMilestone.Kind, [String])] = [
        // Failures first: a panic line must never be reported as progress.
        (.kernelPanic, ["Kernel panic - not syncing", "Kernel panic"]),
        (.rootMountFailure, [
            "Unable to mount root fs",
            "VFS: Cannot open root device",
            // Android first-stage init failing to mount its partitions is the
            // single most common bring-up failure, and it is not a kernel panic.
            "init: Failed to mount required partitions early",
            "init: Failed to create mount namespace",
        ]),
        // Android. Ordered most-specific first: a line announcing
        // `sys.boot_completed` must not also match the zygote pattern.
        (.androidBootCompleted, [
            "sys.boot_completed=1",
            "sys.boot_completed",
            "Boot is finished",
        ]),
        (.androidBootAnimationFinished, [
            "init: Service 'bootanim' (pid",
            "stopping service 'bootanim'",
        ]),
        (.androidZygoteStarted, [
            "Starting service 'zygote'",
            "Zygote: Zygote",
            "zygote64",
        ]),
        (.androidSecondStage, ["init: init second stage started"]),
        (.androidInitStarted, ["init: init first stage started"]),
        // Android-specific failures, checked before the generic ones above by
        // virtue of the failure block at the top of this table.

        // Generic Linux
        (.loginPrompt, ["login:"]),
        // An initramfs that gives up and drops to a shell is still a fully
        // booted kernel with running userspace. For a boot *harness* that is a
        // terminal success — the accelerator, kernel, initrd and virtio path
        // all worked — and it is named distinctly so a report can never present
        // it as a completed system boot.
        (.initramfsShell, [
            "emergency recovery shell launched",
            "Entering emergency mode",
            "Dropping to debug shell",
            "Dropping out of initramfs",
        ]),
        (.userspaceReady, ["Welcome to Alpine", "Run /sbin/init", "systemd[1]:"]),
        (.initStarted, ["Run /init as init process", "Freeing unused kernel memory"]),
        (.kernelMemoryFreed, ["Freeing initrd memory"]),
        (.kernelStarted, ["Booting Linux on physical CPU", "Linux version "]),
    ]

    private var seen: Set<BootMilestone.Kind> = []
    public private(set) var milestones: [BootMilestone] = []

    public init() {}

    /// Feeds one console line. Returns a milestone the first time each kind is
    /// recognised, and `nil` afterwards — a boot log repeats these strings, and
    /// a metric must record the first occurrence, not the last.
    public mutating func consume(line: String, elapsed: Duration) -> BootMilestone? {
        for (kind, needles) in Self.patterns where !seen.contains(kind) {
            for needle in needles where line.contains(needle) {
                seen.insert(kind)
                let milestone = BootMilestone(kind: kind, matchedLine: line, elapsed: elapsed)
                milestones.append(milestone)
                return milestone
            }
        }
        return nil
    }

    public var hasSucceeded: Bool { milestones.contains { $0.kind.isTerminalSuccess } }
    public var hasFailed: Bool { milestones.contains { $0.kind.isTerminalFailure } }
    public var isFinished: Bool { hasSucceeded || hasFailed }

    public func elapsed(for kind: BootMilestone.Kind) -> Duration? {
        milestones.first { $0.kind == kind }?.elapsed
    }

    /// Human-readable timeline for the milestone report.
    public func timeline() -> String {
        milestones
            .map { String(format: "  %8.3f s  %@", $0.elapsed.seconds, $0.kind.rawValue) }
            .joined(separator: "\n")
    }
}
