import AppKit
import Foundation

/// Writes the running window's accessibility tree to a JSON file.
///
/// Screenshots of this interface are unreliable as evidence: `cacheDisplay(in:to:)`
/// does not composite the window's material backdrops, and `NSToolbar` lives
/// outside `contentView` entirely, so both capture blank. Walking the
/// accessibility tree in-process needs no permission, and proves something a
/// screenshot cannot — that every control exists, is reachable, and carries a
/// label a screen reader can read out.
@MainActor
enum AccessibilityDump {

    static func scheduleDump(to url: URL, after delay: Duration = .milliseconds(2500)) {
        Task {
            try? await Task.sleep(for: delay)
            // Retried rather than attempted once. A fixed wait cannot tell
            // "the window is not up yet" from "no window is coming", and those
            // need opposite responses. The summary in the failure line is what
            // distinguishes them once the retries are exhausted.
            var wrote = false
            for _ in 0..<20 {
                wrote = dumpFrontmostWindow(to: url)
                if wrote { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            FileHandle.standardError.write(Data(
                (wrote ? "dumped \(url.path)\n"
                       : "accessibility dump failed — \(windowSummary())\n").utf8))
            // A presented sheet runs a modal session that `terminate` will not
            // end, so the verification run exits once the file is on disk.
            exit(EXIT_SUCCESS)
        }
    }

    /// **Put value-taking flags before bare ones on the command line.**
    ///
    /// `--open-settings --dump-accessibility <path>` produces no window at all;
    /// `--dump-accessibility <path> --open-settings` works. Both orders parse
    /// identically as far as this file is concerned — `overrideRoot(for:)`
    /// finds the same path either way — so the difference is in AppKit, not
    /// here. The likely cause is the user-defaults argument domain, which reads
    /// `-key value` pairs: with the bare flag first it takes
    /// `--dump-accessibility` as the *value* of `-open-settings`, leaving the
    /// path as an orphan argument that the app then appears to treat as
    /// something to open.
    ///
    /// This cost four wrong theories — a modal run-loop mode, statement order
    /// inside `onAppear`, scheduling from `App.init()`, and sheets being
    /// uncapturable in principle — before the failure message was made to say
    /// *what it saw* rather than just "failed". `no windows exist at all` named
    /// the problem in one run. That is what `windowSummary()` below is for.

    /// What the app's windows looked like when a dump could not find one.
    ///
    /// "accessibility dump failed" on its own says nothing a person can act on:
    /// it cannot distinguish "no window exists yet" from "windows exist but
    /// none is visible" from "one is visible but not key". Each has a different
    /// cause and a different fix, and guessing between them cost this project
    /// four wrong theories in a row.
    static func windowSummary() -> String {
        let windows = NSApp.windows
        guard !windows.isEmpty else { return "no windows exist at all" }
        let described = windows.map { window in
            "\(window.className)(title: \"\(window.title)\", "
                + "visible: \(window.isVisible), key: \(window == NSApp.keyWindow), "
                + "\(Int(window.frame.width))x\(Int(window.frame.height)))"
        }
        return "\(windows.count) window(s): " + described.joined(separator: ", ")
    }

    @discardableResult
    static func dumpFrontmostWindow(to url: URL) -> Bool {
        // Prefer an attached sheet, the way `WindowCapture` already did.
        //
        // Without this the dump walks the sheet's *parent* and reports it as a
        // success — which is worse than failing. Measured on 2026-08-27: a
        // `--open-settings` dump came back with two split views and three list
        // rows, byte-for-byte the shape of the main window, while the
        // screenshot of the same run showed the settings form. The dump had
        // been describing the wrong window and saying nothing about it.
        let host = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
        guard let window = host?.attachedSheet ?? host else { return false }

        var tree: [String: Any] = [
            "title": window.title,
            "frame": ["w": Int(window.frame.width), "h": Int(window.frame.height)],
            "window": describe(window, depth: 0),
        ]
        if let content = window.contentView {
            tree["views"] = describeViews(content, depth: 0)
            tree["content"] = describe(content, depth: 0)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: tree, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    /// Depth is bounded because SwiftUI hierarchies are deep and the interesting
    /// controls sit near the top; an unbounded walk produces megabytes of noise.
    private static let maximumDepth = 14

    /// The view hierarchy is always present, unlike the accessibility tree,
    /// so it is the reliable half of the evidence: it shows what the layout
    /// engine actually built and how large each pane came out.
    private static func describeViews(_ view: NSView, depth: Int) -> [String: Any] {
        var node: [String: Any] = [
            "class": String(describing: type(of: view)),
            "frame": ["w": Int(view.frame.width.rounded()), "h": Int(view.frame.height.rounded())],
        ]
        if view.isHidden { node["hidden"] = true }
        if view.alphaValue < 1 { node["alpha"] = view.alphaValue }
        if let label = view.accessibilityLabel(), !label.isEmpty { node["label"] = label }
        if depth < maximumDepth, !view.subviews.isEmpty {
            node["children"] = view.subviews.map { describeViews($0, depth: depth + 1) }
        }
        return node
    }

    private static func describe(_ element: Any, depth: Int) -> [String: Any] {
        var node: [String: Any] = [:]

        if let object = element as? NSAccessibilityProtocol {
            node["role"] = object.accessibilityRole()?.rawValue ?? "unknown"
            if let subrole = object.accessibilitySubrole()?.rawValue { node["subrole"] = subrole }
            if let label = object.accessibilityLabel(), !label.isEmpty { node["label"] = label }
            if let title = object.accessibilityTitle(), !title.isEmpty { node["title"] = title }
            if let value = object.accessibilityValue() as? String, !value.isEmpty {
                node["value"] = value
            }
            if let value = object.accessibilityValue() as? Bool { node["value"] = value }
            if object.isAccessibilityElement() { node["isElement"] = true }
            if !object.isAccessibilityEnabled() { node["enabled"] = false }

            let frame = object.accessibilityFrame()
            if frame.width > 0 || frame.height > 0 {
                node["frame"] = [
                    "w": Int(frame.width.rounded()), "h": Int(frame.height.rounded()),
                ]
            }

            if depth < maximumDepth, let children = object.accessibilityChildren(), !children.isEmpty {
                node["children"] = children.map { describe($0, depth: depth + 1) }
            }
        } else {
            node["role"] = "opaque"
        }
        return node
    }
}
