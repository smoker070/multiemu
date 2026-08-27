import Foundation

/// The summary statistics a performance report is built from.
///
/// In a library with tests rather than inside the measuring executable, because
/// these numbers are the report: a percentile that is off by one rank produces a
/// plausible figure and a wrong conclusion, and nothing downstream would catch
/// it. `docs/PERFORMANCE-METHODOLOGY.md` states the targets these feed.
public enum PerformanceStatistics {

    /// The `fraction` percentile by **nearest rank**.
    ///
    /// Nearest rank rather than linear interpolation: these samples are small
    /// and discrete — a few hundred frame intervals — and interpolating invents
    /// a value between two measurements that were never observed. The result is
    /// always a number the system actually produced.
    ///
    /// `values` must be sorted ascending. Returns 0 for an empty input, which
    /// callers report as "no samples" rather than as a measurement.
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        guard fraction > 0 else { return values[0] }
        let rank = Int((fraction * Double(values.count)).rounded(.up))
        return values[min(max(rank, 1), values.count) - 1]
    }

    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Intervals in milliseconds between successive instants.
    public static func intervalsInMilliseconds(_ instants: [ContinuousClock.Instant]) -> [Double] {
        guard instants.count > 1 else { return [] }
        return zip(instants, instants.dropFirst()).map { $0.duration(to: $1).seconds * 1000 }
    }

    /// Whether frame pacing meets the target: p99 under twice p50.
    ///
    /// A mean rate cannot express this. A guest can average 60 fps while
    /// stuttering badly, which the methodology explicitly does not count as
    /// success — so the comparison is between percentiles, not against an
    /// average.
    public static func pacingIsAcceptable(p50: Double, p99: Double) -> Bool {
        guard p50 > 0 else { return false }
        return p99 < 2 * p50
    }
}
