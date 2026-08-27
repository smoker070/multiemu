import AppKit
import Foundation

/// Captures the application's own window to a PNG.
///
/// Used to verify the interface in an automated run. An application may capture
/// *its own* windows through `cacheDisplay(in:to:)` without the Screen Recording
/// permission, and unlike `ImageRenderer` this draws the real AppKit-backed
/// controls — `NavigationSplitView`, `List`, `Form` and `Picker` all render
/// blank or not at all under `ImageRenderer`, which makes it useless for
/// checking a macOS interface.
@MainActor
enum WindowCapture {

    /// Waits for the window to lay out, captures it, and quits.
    static func scheduleCapture(to url: URL, after delay: Duration = .milliseconds(2500)) {
        Task {
            try? await Task.sleep(for: delay)
            let succeeded = captureFrontmostWindow(to: url)
            FileHandle.standardError.write(Data(
                (succeeded ? "captured \(url.path)\n"
                           : "window capture failed — \(failureDetail())\n").utf8
            ))
            // A presented sheet runs a modal session that `terminate` will not
            // end, so the verification run exits once the file is on disk.
            exit(EXIT_SUCCESS)
        }
    }

    /// Which of the five ways this can fail actually happened.
    ///
    /// `window capture failed` collapses "no window", "no content view", "a
    /// window one pixel wide", "AppKit would not make a bitmap" and "the PNG
    /// would not write" into one string, and those have nothing in common. The
    /// same shortcut in `AccessibilityDump` cost four wrong theories before the
    /// message was made to name what it saw; this is the same message, in the
    /// same file's sibling, so it gets the same treatment before it costs the
    /// same again.
    static func failureDetail() -> String {
        let host = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
        guard let window = host?.attachedSheet ?? host else {
            let windows = NSApp.windows
            guard !windows.isEmpty else { return "no windows exist at all" }
            return "\(windows.count) window(s), none key or visible: "
                + windows.map { "\($0.className)(visible: \($0.isVisible))" }
                    .joined(separator: ", ")
        }
        guard let view = window.contentView else {
            return "\(window.className) \"\(window.title)\" has no content view"
        }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            return "\"\(window.title)\" is \(Int(bounds.width))x\(Int(bounds.height)) — too small to capture"
        }
        guard view.bitmapImageRepForCachingDisplay(in: bounds) != nil else {
            return "AppKit would not make a bitmap for \"\(window.title)\" "
                + "at \(Int(bounds.width))x\(Int(bounds.height))"
        }
        return "the bitmap was made but could not be encoded or written to disk"
    }

    @discardableResult
    static func captureFrontmostWindow(to url: URL) -> Bool {
        // Which window is key when a sheet is going up is a race, so prefer the
        // sheet explicitly: capturing its parent instead would silently produce
        // a screenshot of the wrong thing.
        let host = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
        guard let window = host?.attachedSheet ?? host,
              let view = window.contentView else { return false }

        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }

        view.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return false }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return (try? data.write(to: url)) != nil
    }
}
