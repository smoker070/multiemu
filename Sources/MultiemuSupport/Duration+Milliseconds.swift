import Foundation

extension Duration {
    /// Milliseconds as a `Double`.
    ///
    /// Every performance number Multiemu reports goes through this, so the
    /// conversion exists once rather than being re-derived from
    /// `components` at each call site.
    public var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1_000_000_000_000_000
    }

    public var seconds: Double {
        milliseconds / 1_000
    }
}
