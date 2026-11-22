import Foundation

/// Choosing the rate a device should run at.
///
/// Rates are whole hertz. Core Audio takes them as `Float64` because the property
/// system has no integer type, but every rate a device or a file names is an integer,
/// and carrying them as `Double` invites arithmetic on them that no rate needs.
enum OutputSampleRate {
    /// The rate to ask for, given what the device can do.
    ///
    /// The requested rate when the device runs it, otherwise the lowest supported
    /// rate at or above it — never a lower one. A device running faster than its
    /// input resamples and keeps everything; one running slower loses the band
    /// above its own Nyquist for good.
    ///
    /// Above everything the device offers, its highest rate is the least wrong
    /// answer. No ranges at all returns nil rather than a plausible default.
    static func atOrAbove(_ rate: Int, among ranges: [ClosedRange<Int>]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        if ranges.contains(where: { $0.contains(rate) }) { return rate }

        // The cheapest ceiling: anything higher is a wider filter for no gain.
        let ceilings = ranges.map(\.lowerBound).filter { $0 > rate }
        if let lowest = ceilings.min() { return lowest }

        return ranges.map(\.upperBound).max()
    }
}
