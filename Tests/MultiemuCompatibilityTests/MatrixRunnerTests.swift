import Foundation
import Testing
@testable import MultiemuCompatibility

/// The matrix is only worth having if it reports what actually happened. These
/// cover the decision itself — especially the case where a claim names evidence
/// that no longer exists, which is the drift this milestone was built to catch.
@Suite("Compatibility matrix")
struct MatrixRunnerTests {

    private func makeRunner() -> MatrixRunner {
        MatrixRunner(configuration: .init(
            packageDirectory: URL(fileURLWithPath: "/tmp"),
            binaryDirectory: URL(fileURLWithPath: "/tmp"),
            kernelURL: URL(fileURLWithPath: "/tmp/kernel"),
            initrdURL: URL(fileURLWithPath: "/tmp/initrd"),
            runsSpikes: false))
    }

    private func claim(_ primary: Evidence, intel: Evidence = .sameAsPrimary) -> CompatibilityClaim {
        CompatibilityClaim(
            id: "test", section: .boot, capability: "A capability",
            primary: primary, intel: intel, milestone: "M0")
    }

    @Test("A passing suite makes the claim supported")
    func passingSuiteSupports() {
        let outcome = makeRunner().evaluate(
            claim(.suite("Present")), suites: ["Present": true], spikes: [:])
        #expect(outcome.primary == .supported)
    }

    @Test("A failing suite fails the claim")
    func failingSuiteFails() {
        let outcome = makeRunner().evaluate(
            claim(.suite("Present")), suites: ["Present": false], spikes: [:])
        #expect(outcome.primary == .failed)
        #expect(outcome.isFailure)
    }

    @Test("A claim naming a suite that did not run FAILS, rather than passing quietly")
    func missingSuiteIsDrift() {
        // This is the whole point. A suite renamed or deleted while its claim
        // stays behind is drift, and a matrix that shrugged at it would go on
        // asserting something nothing checks.
        let outcome = makeRunner().evaluate(
            claim(.suite("Renamed away")), suites: ["Something else": true], spikes: [:])
        #expect(outcome.primary == .failed)
        #expect(outcome.primaryDetail.contains("no test suite named"))
    }

    @Test("A spike that was not run reads as untested, not as passing")
    func unrunSpikeIsUntested() {
        let outcome = makeRunner().evaluate(
            claim(.spike(product: "some-spike")), suites: [:], spikes: [:])
        #expect(outcome.primary == .notTested)
        #expect(!outcome.isFailure)
    }

    @Test("Both halves must pass when a claim names a suite and a spike")
    func suiteAndSpikeBothCount() {
        let runner = makeRunner()
        let evidence = Evidence.suiteAndSpike(suite: "Present", product: "some-spike")

        // The suite passing is not enough on its own.
        let suiteOnly = runner.evaluate(claim(evidence), suites: ["Present": true], spikes: [:])
        #expect(suiteOnly.primary == .notTested)

        // A failing suite short-circuits before the spike is considered.
        let suiteFailed = runner.evaluate(claim(evidence), suites: ["Present": false], spikes: [:])
        #expect(suiteFailed.primary == .failed)

        let invocation = MatrixRunner.SpikeInvocation(product: "some-spike", arguments: [])
        let both = runner.evaluate(
            claim(evidence), suites: ["Present": true], spikes: [invocation: true])
        #expect(both.primary == .supported)
    }

    @Test("Blocked and unavailable claims say so, and are not failures")
    func blockedAndUnavailableAreNotFailures() {
        let blocked = makeRunner().evaluate(
            claim(.blocked(by: "M4", reason: "no image")), suites: [:], spikes: [:])
        #expect(blocked.primary == .blocked)
        #expect(blocked.primaryDetail.contains("M4"))
        #expect(!blocked.isFailure)

        let unavailable = makeRunner().evaluate(
            claim(.unavailable(reason: "no hardware")), suites: [:], spikes: [:])
        #expect(unavailable.primary == .unavailable)
        #expect(!unavailable.isFailure)
    }

    @Test("A host-independent claim mirrors the primary result without claiming to have run")
    func mirroredClaimsSaySo() {
        let outcome = makeRunner().evaluate(
            claim(.suite("Present"), intel: .sameAsPrimary),
            suites: ["Present": true], spikes: [:])
        #expect(outcome.intel == .supported)
        // It must not read as though it ran on the other architecture.
        #expect(outcome.intelDetail.contains("host-independent"))
    }

    @Test("Placeholders are replaced with the guest images actually given")
    func placeholdersResolve() {
        let resolved = makeRunner().resolve(
            ["--kernel", ClaimRegistry.kernelPlaceholder, "--initrd", ClaimRegistry.initrdPlaceholder])
        #expect(resolved == ["--kernel", "/tmp/kernel", "--initrd", "/tmp/initrd"])
    }

    @Test("Every claim in the registry is uniquely identified and names its milestone")
    func registryIsWellFormed() {
        let identifiers = ClaimRegistry.all.map(\.id)
        #expect(Set(identifiers).count == identifiers.count, "duplicate claim id")
        for claim in ClaimRegistry.all {
            #expect(!claim.capability.isEmpty)
            #expect(claim.milestone.hasPrefix("M"))
        }
    }

    @Test("Every suite a claim names exists in this package's tests")
    func namedSuitesExist() throws {
        // Catches drift at the moment it is introduced, rather than at the next
        // full matrix run.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var declared: Set<String> = []
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                var remainder = Substring(text)
                while let marker = remainder.range(of: "@Suite(\"") {
                    remainder = remainder[marker.upperBound...]
                    if let close = remainder.firstIndex(of: "\"") {
                        declared.insert(String(remainder[..<close]))
                    }
                }
            }
        }

        for claim in ClaimRegistry.all {
            let named: String?
            switch claim.primary {
            case let .suite(name): named = name
            case let .suiteAndSpike(name, _, _): named = name
            default: named = nil
            }
            guard let named else { continue }
            #expect(declared.contains(named), "claim \(claim.id) names a suite that does not exist: \(named)")
        }
    }
}
