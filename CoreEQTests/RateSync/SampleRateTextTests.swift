import Foundation
import Testing

/// How a rate is written in the window.
struct SampleRateTextTests {

    @Test func aWholeKilohertzDropsTheDecimal() {
        #expect(SampleRateText.format(48000) == "48 kHz")
        #expect(SampleRateText.format(96000) == "96 kHz")
        #expect(SampleRateText.format(88200) == "88.2 kHz")
    }

    @Test func theRatePeopleKnowIsWrittenTheWayTheyKnowIt() {
        #expect(SampleRateText.format(44100) == "44.1 kHz")
    }

    /// A rate nothing matches exactly must read as a real number rather than being
    /// rounded into one it is not.
    @Test func anOddRateKeepsOneDecimal() {
        #expect(SampleRateText.format(46034) == "46.0 kHz")
    }
}
