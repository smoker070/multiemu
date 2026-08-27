import Foundation
import Testing

@testable import MultiemuViewModels

/// Which binary the application spawns decides whether a shipped build works at
/// all, so the search order is pinned down here rather than left to the machine
/// the developer happens to be on.
///
/// Serialised because the override is read from the process environment.
@Suite("Helper location", .serialized)
struct HelperLocatorTests {

    private func makeExecutable(_ directory: URL, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiemu-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A bundled helper is preferred over anything installed on the machine")
    func bundledWins() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(root, "qemu-img")

        let resolution = HelperLocator(bundleHelpersDirectory: root).locate("qemu-img")
        #expect(resolution.source == .bundledHelper)
        #expect(resolution.url?.path == root.appendingPathComponent("qemu-img").path)
        #expect(resolution.isAvailable)
    }

    @Test("A missing helper reports every path it looked in")
    func missingReportsSearchedPaths() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let resolution = HelperLocator(bundleHelpersDirectory: root)
            .locate("multiemu-nonexistent-helper")
        #expect(!resolution.isAvailable)
        #expect(resolution.source == .missing)
        // The bundle, plus both development prefixes: a diagnostic the user can act on.
        #expect(resolution.searchedPaths.count == 3)
        #expect(resolution.searchedPaths.first?.hasPrefix(root.path) == true)
    }

    @Test("The environment override replaces the search entirely")
    func overrideReplacesSearch() throws {
        let bundle = try scratch()
        let override = try scratch()
        defer {
            try? FileManager.default.removeItem(at: bundle)
            try? FileManager.default.removeItem(at: override)
        }
        try makeExecutable(bundle, "qemu-img")
        try makeExecutable(override, "qemu-img")

        setenv(HelperLocator.overrideVariable, override.path, 1)
        defer { unsetenv(HelperLocator.overrideVariable) }

        let resolution = HelperLocator(bundleHelpersDirectory: bundle).locate("qemu-img")
        #expect(resolution.url?.path == override.appendingPathComponent("qemu-img").path)
        #expect(resolution.searchedPaths.count == 1)
    }

    @Test("An override pointing at nothing fails rather than falling back")
    func overrideDoesNotFallBack() throws {
        let bundle = try scratch()
        let override = try scratch()
        defer {
            try? FileManager.default.removeItem(at: bundle)
            try? FileManager.default.removeItem(at: override)
        }
        try makeExecutable(bundle, "qemu-img")

        setenv(HelperLocator.overrideVariable, override.path, 1)
        defer { unsetenv(HelperLocator.overrideVariable) }

        // Falling back would silently run a different binary than the one asked for.
        let resolution = HelperLocator(bundleHelpersDirectory: bundle).locate("qemu-img")
        #expect(!resolution.isAvailable)
        #expect(resolution.source == .missing)
    }

    @Test("The emulator binary is chosen by guest architecture")
    func emulatorNamePerArchitecture() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(root, "qemu-system-aarch64")

        let locator = HelperLocator(bundleHelpersDirectory: root)
        #expect(locator.locateEmulator(for: .arm64).url?.lastPathComponent == "qemu-system-aarch64")
        #expect(locator.locateEmulator(for: .x86_64).searchedPaths
            .allSatisfy { $0.hasSuffix("qemu-system-x86_64") })
    }
}
