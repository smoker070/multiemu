import Foundation
import Testing
@testable import MultiemuSupport

@Suite("Performance statistics")
struct PerformanceStatisticsTests {

    private let ten = Array(1...10).map(Double.init)   // 1...10

    @Test("A percentile returns a value that was actually measured")
    func percentileIsAnObservedValue() {
        // Nearest rank, so every answer is one of the inputs — never a value
        // interpolated between two samples that was never observed.
        for fraction in stride(from: 0.05, through: 1.0, by: 0.05) {
            let result = PerformanceStatistics.percentile(ten, fraction)
            #expect(ten.contains(result), "p\(Int(fraction * 100)) produced \(result)")
        }
    }

    @Test("Known percentiles land on the documented ranks")
    func knownPercentiles() {
        #expect(PerformanceStatistics.percentile(ten, 0.50) == 5)
        #expect(PerformanceStatistics.percentile(ten, 0.95) == 10)
        #expect(PerformanceStatistics.percentile(ten, 0.99) == 10)
        #expect(PerformanceStatistics.percentile(ten, 1.0) == 10)
    }

    @Test("p99 of a hundred samples is the 99th, not the 100th")
    func p99DoesNotSilentlyBecomeTheMaximum() {
        // The off-by-one that matters: if p99 collapses to max, a single
        // outlier fails the pacing target on its own and the report blames
        // the wrong thing.
        var values = Array(repeating: 10.0, count: 99)
        values.append(9999)
        #expect(PerformanceStatistics.percentile(values, 0.99) == 10)
        #expect(PerformanceStatistics.percentile(values, 1.0) == 9999)
    }

    @Test("A single sample is its own every percentile")
    func singleSample() {
        #expect(PerformanceStatistics.percentile([42], 0.50) == 42)
        #expect(PerformanceStatistics.percentile([42], 0.99) == 42)
    }

    @Test("No samples reports zero rather than crashing")
    func emptyInput() {
        #expect(PerformanceStatistics.percentile([], 0.5) == 0)
        #expect(PerformanceStatistics.mean([]) == 0)
        #expect(PerformanceStatistics.intervalsInMilliseconds([]).isEmpty)
    }

    @Test("The mean is the arithmetic mean")
    func meanIsTheMean() {
        #expect(PerformanceStatistics.mean([1, 2, 3, 4]) == 2.5)
        #expect(PerformanceStatistics.mean([5]) == 5)
    }

    @Test("One instant yields no interval, because an interval needs two")
    func intervalsNeedTwoInstants() {
        #expect(PerformanceStatistics.intervalsInMilliseconds([.now]).isEmpty)
    }

    @Test("Pacing passes only when p99 is under twice p50")
    func pacingTarget() {
        #expect(PerformanceStatistics.pacingIsAcceptable(p50: 16, p99: 31))
        #expect(PerformanceStatistics.pacingIsAcceptable(p50: 16, p99: 32) == false)
        // A steady stream with no jitter passes.
        #expect(PerformanceStatistics.pacingIsAcceptable(p50: 16.7, p99: 16.7))
        // Nothing measured cannot pass.
        #expect(PerformanceStatistics.pacingIsAcceptable(p50: 0, p99: 0) == false)
    }

    @Test("A high mean rate does not rescue pacing when stutter is common")
    func meanRateDoesNotHidePacing() {
        // 5% of frames take 200 ms. The mean rate still looks healthy, and the
        // pacing target is what catches it.
        var intervals = Array(repeating: 16.0, count: 95)
        intervals.append(contentsOf: Array(repeating: 200.0, count: 5))
        let sorted = intervals.sorted()
        #expect(1000 / PerformanceStatistics.mean(intervals) > 30, "the mean rate looks healthy")
        #expect(PerformanceStatistics.pacingIsAcceptable(
            p50: PerformanceStatistics.percentile(sorted, 0.50),
            p99: PerformanceStatistics.percentile(sorted, 0.99)) == false)
    }

    @Test("A single outlier in a hundred frames does not move p99 — a limit of the target")
    func oneOutlierInAHundredDoesNotFailP99() {
        // Worth pinning down rather than discovering later: with 100 samples,
        // nearest-rank p99 is the 99th value, so exactly one bad frame sits
        // above it and the target passes. The criterion measures how *common*
        // stutter is, not whether it ever happened; the longest-interval figure
        // in the report is what shows a lone spike.
        var intervals = Array(repeating: 16.0, count: 99)
        intervals.append(9999)
        let sorted = intervals.sorted()
        #expect(PerformanceStatistics.percentile(sorted, 0.99) == 16)
        #expect(PerformanceStatistics.pacingIsAcceptable(
            p50: PerformanceStatistics.percentile(sorted, 0.50),
            p99: PerformanceStatistics.percentile(sorted, 0.99)))
        #expect(sorted.last == 9999, "the spike is only visible as the longest interval")
    }
}
