import Foundation
import os

/// Identifiers used for every `os_log` / signpost emission in Multiemu.
///
/// A single, stable subsystem string means a user can hand us one command
/// (`log show --predicate 'subsystem == "com.multiemu.Multiemu"'`) and get the
/// whole picture, including messages emitted by helper processes.
public enum MultiemuSubsystem {
    public static let identifier = "com.multiemu.Multiemu"
}

/// Log categories. These map 1:1 onto the module boundaries defined in
/// `docs/ARCHITECTURE.md` so a category always tells you which component spoke.
public enum LogCategory: String, Sendable, CaseIterable, Codable {
    case host          // host capability detection
    case lifecycle     // emulator lifecycle coordinator
    case backend       // virtualization/emulation backend
    case image         // Android image manager
    case profile       // virtual-device profiles
    case boot          // boot configuration and guest boot progress
    case graphics      // display and rendering pipeline
    case input         // keyboard / mouse / touch / gamepad translation
    case audio         // audio input/output
    case network       // virtual networking
    case adb           // ADB integration
    case storage       // disks, userdata, sparse allocation
    case snapshot      // snapshots
    case clipboard     // clipboard integration
    case fileExchange  // host/guest file exchange
    case packages      // APK installation
    case config        // configuration persistence
    case diagnostics   // diagnostics, crash detection, recovery
    case performance   // performance instrumentation
    case ui            // macOS application shell
    case release       // update and release infrastructure
}

/// Namespaced access to `Logger` instances.
///
/// These are computed rather than stored so that no mutable global state exists
/// under Swift 6 strict concurrency, and so a helper process can create loggers
/// lazily without touching the main actor.
public enum MultiemuLog {
    public static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: MultiemuSubsystem.identifier, category: category.rawValue)
    }

    public static var host: Logger { logger(.host) }
    public static var lifecycle: Logger { logger(.lifecycle) }
    public static var backend: Logger { logger(.backend) }
    public static var boot: Logger { logger(.boot) }
    public static var graphics: Logger { logger(.graphics) }
    public static var input: Logger { logger(.input) }
    public static var storage: Logger { logger(.storage) }
    public static var snapshot: Logger { logger(.snapshot) }
    public static var diagnostics: Logger { logger(.diagnostics) }
    public static var performance: Logger { logger(.performance) }
}
