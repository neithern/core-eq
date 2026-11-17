import Foundation
import Testing

/// Choosing the rate a device should run at, given the material.
struct OutputSampleRateTests {

    private let display: [ClosedRange<Int>] = [
        44100...44100, 48000...48000, 88200...88200, 96000...96000,
    ]

    /// Bluetooth headphones, which offer far less than a display does.
    private let headphones: [ClosedRange<Int>] = [16000...16000, 44100...44100]

    @Test func aSupportedRateIsKept() {
        #expect(OutputSampleRate.atOrAbove(48000, among: display) == 48000)
    }

    /// A rate inside a range is runnable, so it is not snapped to an endpoint.
    @Test func aRateInsideARangeIsKept() {
        let continuous = [44100...96000]
        #expect(OutputSampleRate.atOrAbove(50000, among: continuous) == 50000)
    }

    /// The rule this type exists for: the device never runs slower than the
    /// material, because the band above its Nyquist is gone for good.
    @Test func anUnsupportedRateRoundsUp() {
        #expect(OutputSampleRate.atOrAbove(44000, among: display) == 44100)
        #expect(OutputSampleRate.atOrAbove(45000, among: display) == 48000)
        #expect(OutputSampleRate.atOrAbove(50000, among: display) == 88200)
    }

    /// The lowest ceiling, not the highest: once the material fits, a wider
    /// filter buys nothing.
    @Test func theCheapestCeilingIsChosen() {
        #expect(OutputSampleRate.atOrAbove(41000, among: display) == 44100)
        #expect(OutputSampleRate.atOrAbove(44101, among: display) == 48000)
    }

    @Test func anImpossiblyHighRateClampsToTheHighest() {
        #expect(OutputSampleRate.atOrAbove(384000, among: display) == 96000)
    }

    /// Bluetooth's only two rates. 22.05 kHz material must go *up* to 44.1,
    /// never down to 16 — downward would lose the whole of 8–11 kHz.
    @Test func materialAboveADevicesLowestRateGoesUp() {
        #expect(OutputSampleRate.atOrAbove(22050, among: headphones) == 44100)
        #expect(OutputSampleRate.atOrAbove(8000, among: headphones) == 16000)
        #expect(OutputSampleRate.atOrAbove(48000, among: headphones) == 44100)
    }

    @Test func aDeviceThatWillNotAnswerProducesNoRate() {
        #expect(OutputSampleRate.atOrAbove(44100, among: []) == nil)
    }
}
