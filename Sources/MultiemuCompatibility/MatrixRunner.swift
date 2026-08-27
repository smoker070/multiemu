import Foundation
import MultiemuSupport

/// Runs the claims and reports what actually happened.
///
/// Two sources of truth are consulted: the package's own test suites, and the
/// spikes that exercise a live guest. Nothing is inferred — a claim whose
/// evidence did not run is reported as untested, and a claim naming evidence
/// that does not exist is reported as **failed**, because that is drift and
/// drift is exactly what this milestone exists to catch.
public struct MatrixRunner: Sendable {

    public struct Configuration: Sendable {
        public var packageDirectory: URL
        public var binaryDirectory: URL
        public var kernelURL: URL?
        public var initrdURL: URL?
        /// Spikes boot real guests and take minutes. Skipping them is allowed,
        /// but every claim they back is then reported as untested rather than
        /// inheriting a previous result.
        public var runsSpikes: Bool
        public var spikeTimeout: TimeInterval

        public init(
            packageDirectory: URL,
            binaryDirectory: URL,
            kernelURL: URL? = nil,
            initrdURL: URL? = nil,
            runsSpikes: Bool = true,
            spikeTimeout: TimeInterval = 300
        ) {
            self.packageDirectory = packageDirectory
            self.binaryDirectory = binaryDirectory
            self.kernelURL = kernelURL
            self.initrdURL = initrdURL
            self.runsSpikes = runsSpikes
            self.spikeTimeout = spikeTimeout
        }
    }

    public struct Report: Sendable {
        public var outcomes: [ClaimOutcome]
        public var suitesRun: Int
        public var suitesFailed: [String]
        public var spikesRun: [String]
        public var spikesFailed: [String]
        /// The individual issues the test run reported. Without these a failing
        /// claim says only that a suite failed, which is where the diagnosis
        /// stops rather than starts.
        public var testIssues: [String]
        public var startedAt: Date
        public var duration: TimeInterval
        public var hostDescription: String

        public var failures: [ClaimOutcome] { outcomes.filter(\.isFailure) }
        public func count(_ status: ClaimStatus) -> Int {
            outcomes.filter { $0.primary == status }.count
        }
    }

    public let configuration: Configuration
    private let progress: @Sendable (String) -> Void

    public init(configuration: Configuration, progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.progress = progress
    }

    // MARK: - Running

    public func run(hostDescription: String) async -> Report {
        let started = Date()

        progress("Running the test suites…")
        let (suiteResults, issues) = runTestSuites()
        progress("  \(suiteResults.count) suites reported, \(suiteResults.values.filter { !$0 }.count) failing")

        var spikeResults: [SpikeInvocation: Bool] = [:]
        var spikesRun: [String] = []
        if configuration.runsSpikes {
            for invocation in Set(requiredSpikes()).sorted(by: { $0.label < $1.label }) {
                progress("Running \(invocation.label)…")
                let passed = runSpike(invocation)
                spikeResults[invocation] = passed
                spikesRun.append(invocation.label)
                progress("  \(invocation.label): \(passed ? "PASS" : "FAIL")")
            }
        } else {
            progress("Skipping spikes; every claim they back will read as untested.")
        }

        let outcomes = ClaimRegistry.all.map {
            evaluate($0, suites: suiteResults, spikes: spikeResults)
        }

        return Report(
            outcomes: outcomes,
            suitesRun: suiteResults.count,
            suitesFailed: suiteResults.filter { !$0.value }.keys.sorted(),
            spikesRun: spikesRun,
            spikesFailed: spikeResults.filter { !$0.value }.keys.map(\.label).sorted(),
            testIssues: issues,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            hostDescription: hostDescription)
    }

    // MARK: - Suites

    /// Runs the package's tests once and reads each suite's verdict from the
    /// output, rather than running a process per claim.
    private func runTestSuites() -> (suites: [String: Bool], issues: [String]) {
        let output = execute(
            "/usr/bin/env",
            arguments: ["swift", "test"],
            workingDirectory: configuration.packageDirectory,
            timeout: 1800).output

        var results: [String: Bool] = [:]
        var issues: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.contains("recorded an issue") || text.contains("error:") {
                issues.append(text.trimmingCharacters(in: .whitespaces))
            }
            guard text.contains("Suite "), let name = quotedName(in: text) else { continue }
            if text.contains("passed") {
                // A suite that failed earlier in the run must not be overwritten
                // by a later "passed" line for a different reason.
                results[name] = results[name] ?? true
            } else if text.contains("failed") {
                results[name] = false
            }
        }
        return (results, issues)
    }

    private func quotedName(in line: String) -> String? {
        guard let start = line.range(of: "\""),
              let end = line.range(of: "\"", range: start.upperBound..<line.endIndex)
        else { return nil }
        return String(line[start.upperBound..<end.lowerBound])
    }

    // MARK: - Spikes

    struct SpikeInvocation: Hashable, Sendable {
        var product: String
        var arguments: [String]
        /// A script is identified by its path; a spike by its product name.
        var isScript: Bool = false
        var label: String { product }
    }

    private func requiredSpikes() -> [SpikeInvocation] {
        ClaimRegistry.all.flatMap { claim -> [SpikeInvocation] in
            [claim.primary, claim.intel].compactMap { evidence in
                switch evidence {
                case let .spike(product, arguments):
                    return SpikeInvocation(product: product, arguments: resolve(arguments))
                case let .suiteAndSpike(_, product, arguments):
                    return SpikeInvocation(product: product, arguments: resolve(arguments))
                case let .script(path, arguments):
                    return SpikeInvocation(product: path, arguments: resolve(arguments), isScript: true)
                default:
                    return nil
                }
            }
        }
    }

    /// Substitutes the guest kernel paths the spikes need.
    func resolve(_ arguments: [String]) -> [String] {
        arguments.map { argument in
            switch argument {
            case ClaimRegistry.kernelPlaceholder: return configuration.kernelURL?.path ?? ""
            case ClaimRegistry.initrdPlaceholder: return configuration.initrdURL?.path ?? ""
            default: return argument
            }
        }
    }

    private func runSpike(_ invocation: SpikeInvocation) -> Bool {
        let binary = invocation.isScript
            ? configuration.packageDirectory.appendingPathComponent(invocation.product)
            : configuration.binaryDirectory.appendingPathComponent(invocation.product)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return false }
        // A spike that needs a guest kernel and was given none cannot pass, and
        // must not be recorded as if it had run.
        if invocation.arguments.contains("") { return false }
        return execute(
            binary.path,
            arguments: invocation.arguments,
            workingDirectory: configuration.packageDirectory,
            timeout: configuration.spikeTimeout).status == 0
    }

    // MARK: - Evaluating

    func evaluate(
        _ claim: CompatibilityClaim,
        suites: [String: Bool],
        spikes: [SpikeInvocation: Bool]
    ) -> ClaimOutcome {
        let primary = status(of: claim.primary, suites: suites, spikes: spikes, mirroring: nil)
        let intel = status(of: claim.intel, suites: suites, spikes: spikes, mirroring: primary)
        return ClaimOutcome(
            claim: claim,
            primary: primary.status, intel: intel.status,
            primaryDetail: primary.detail, intelDetail: intel.detail)
    }

    func status(
        of evidence: Evidence,
        suites: [String: Bool],
        spikes: [SpikeInvocation: Bool],
        mirroring primary: (status: ClaimStatus, detail: String)?
    ) -> (status: ClaimStatus, detail: String) {
        switch evidence {
        case let .suite(name):
            return suiteStatus(name, suites: suites)

        case let .spike(product, arguments):
            return spikeStatus(SpikeInvocation(product: product, arguments: resolve(arguments)), spikes: spikes)

        case let .script(path, arguments):
            return spikeStatus(
                SpikeInvocation(product: path, arguments: resolve(arguments), isScript: true),
                spikes: spikes)

        case let .suiteAndSpike(name, product, arguments):
            let suite = suiteStatus(name, suites: suites)
            guard suite.status == .supported else { return suite }
            let spike = spikeStatus(
                SpikeInvocation(product: product, arguments: resolve(arguments)), spikes: spikes)
            guard spike.status == .supported else { return spike }
            return (.supported, "suite \"\(name)\" and \(product)")

        case .sameAsPrimary:
            guard let primary else { return (.notTested, "nothing to mirror") }
            // Host-independent logic inherits the verdict but never the claim of
            // having been *run* on the other architecture.
            return (primary.status == .supported ? .supported : primary.status,
                    "host-independent; \(primary.detail)")

        case let .unavailable(reason):
            return (.unavailable, reason)

        case let .blocked(by, reason):
            return (.blocked, "blocked by \(by): \(reason)")
        }
    }

    func suiteStatus(_ name: String, suites: [String: Bool]) -> (status: ClaimStatus, detail: String) {
        guard let passed = suites[name] else {
            // The claim names a suite that did not run. That is drift between
            // the matrix and the tests, and it is reported as a failure rather
            // than quietly ignored.
            return (.failed, "no test suite named \"\(name)\" ran")
        }
        return passed ? (.supported, "suite \"\(name)\"") : (.failed, "suite \"\(name)\" failed")
    }

    func spikeStatus(
        _ invocation: SpikeInvocation, spikes: [SpikeInvocation: Bool]
    ) -> (status: ClaimStatus, detail: String) {
        guard let passed = spikes[invocation] else {
            return (.notTested, "\(invocation.product) was not run")
        }
        return passed ? (.supported, invocation.product) : (.failed, "\(invocation.product) failed")
    }

    // MARK: - Process

    private func execute(
        _ launchPath: String, arguments: [String], workingDirectory: URL, timeout: TimeInterval
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Read on a separate thread: a full test run fills a pipe buffer long
        // before it exits, and waiting first would deadlock.
        final class OutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
            var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
        }
        let collected = OutputBuffer()
        let reader = Thread {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
        }
        reader.start()

        do { try process.run() } catch { return (127, "could not run \(launchPath): \(error)") }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            return (124, collected.text)
        }
        process.waitUntilExit()
        // Give the reader a moment to drain what is left.
        usleep(200_000)
        return (process.terminationStatus, collected.text)
    }
}
