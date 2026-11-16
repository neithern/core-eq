import Foundation
import Testing

/// Choosing the nearest rate a device can actually run.
struct OutputSampleRateTests {

    private let display: [ClosedRange<Int>] = [
        44100...44100, 48000...48000, 88200...88200, 96000...96000,
    ]

    @Test func aSupportedRateIsKept() {
        #expect(OutputSampleRate.nearest(to: 48000, among: display) == 48000)
    }

    /// A rate inside a range is runnable, so it is not snapped to an endpoint.
    @Test func aRateInsideARangeIsKept() {
        let continuous = [44100...96000]
        #expect(OutputSampleRate.nearest(to: 50000, among: continuous) == 50000)
    }

    @Test func anUnsupportedRateSnapsDown() {
        #expect(OutputSampleRate.nearest(to: 44000, among: display) == 44100)
    }

    @Test func anUnsupportedRateSnapsUp() {
        #expect(OutputSampleRate.nearest(to: 45000, among: display) == 44100)
    }

    @Test func anImpossiblyHighRateClampsToTheHighest() {
        #expect(OutputSampleRate.nearest(to: 384000, among: display) == 96000)
    }

    @Test func anImpossiblyLowRateClampsToTheLowest() {
        #expect(OutputSampleRate.nearest(to: 8000, among: display) == 44100)
    }

    @Test func aDeviceThatWillNotAnswerProducesNoRate() {
        #expect(OutputSampleRate.nearest(to: 44100, among: []) == nil)
    }

    /// A half-way point between two supported rates goes up: upsampling loses less
    /// than downsampling.
    @Test func aTiePrefersTheHigherRate() {
        let twoRates = [44100...44100, 48000...48000]
        let midpoint = (44100 + 48000) / 2
        #expect(OutputSampleRate.nearest(to: midpoint, among: twoRates) == 48000)
    }
}
