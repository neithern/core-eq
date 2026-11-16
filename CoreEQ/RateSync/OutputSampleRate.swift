import Foundation

/// Choosing the supported rate nearest to one a device does not offer.
///
/// Rates are whole hertz. Core Audio takes them as `Float64` because the property
/// system has no integer type, but every rate a device or a file names is an integer,
/// and carrying them as `Double` invites arithmetic on them that no rate needs.
enum OutputSampleRate {
    /// The rate to ask for, given what the device can do.
    ///
    /// Returns the requested rate when it is runnable, otherwise the nearest rate
    /// that is. Ties prefer the higher rate, on the grounds that upsampling loses
    /// less than downsampling. No ranges at all — a device that would not answer —
    /// returns nil rather than a plausible-looking default.
    static func nearest(to rate: Int, among ranges: [ClosedRange<Int>]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        if ranges.contains(where: { $0.contains(rate) }) { return rate }

        let candidates = ranges.flatMap { [$0.lowerBound, $0.upperBound] }
        return candidates.min { first, second in
            let firstDistance = abs(first - rate)
            let secondDistance = abs(second - rate)
            if firstDistance != secondDistance { return firstDistance < secondDistance }
            return first > second
        }
    }
}
