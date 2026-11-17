import Foundation
import Testing

/// Whether the device is written, and to what.
///
/// What is being guarded is the hardware: a write reconfigures whatever else holds
/// the device, so each rule either prevents a pointless one or prevents one the
/// device cannot honour.
struct RateSyncPolicyTests {

    private let studioDisplay: [ClosedRange<Int>] = [
        44100...44100, 48000...48000, 88200...88200, 96000...96000,
    ]

    private func device(
        rate: Int? = 48000,
        supported: [ClosedRange<Int>]? = nil,
        isAggregate: Bool = false
    ) -> RateSyncPolicy.DeviceState {
        RateSyncPolicy.DeviceState(
            rate: rate,
            supportedRates: supported ?? studioDisplay,
            isAggregate: isAggregate)
    }

    @Test func anAggregateOutputIsNeverRetuned() {
        let decision = RateSyncPolicy.decide(
            sourceRate: 44100, device: device(isAggregate: true))
        #expect(decision == .nothing(.aggregateOutput))
    }

    @Test func aDeviceWithNoKnownRatesIsLeftAlone() {
        let state = RateSyncPolicy.DeviceState(
            rate: 48000, supportedRates: [], isAggregate: false)
        #expect(
            RateSyncPolicy.decide(sourceRate: 44100, device: state) == .nothing(.noSupportedRates))
    }

    @Test func aDifferentRateIsWritten() {
        #expect(
            RateSyncPolicy.decide(sourceRate: 44100, device: device(rate: 48000))
                == .write(rate: 44100))
    }

    /// 176400 is above everything the device offers, so it takes the highest.
    @Test func aRateTheDeviceLacksSnapsUpward() {
        #expect(
            RateSyncPolicy.decide(sourceRate: 176400, device: device(rate: 44100))
                == .write(rate: 96000))
    }

    /// A device that already runs faster than the material is left alone when it
    /// is the cheapest rate that still covers it — no write, no reconfiguration.
    @Test func aDeviceAlreadyAtTheRightRateIsNotRewritten() {
        #expect(
            RateSyncPolicy.decide(sourceRate: 45000, device: device(rate: 48000))
                == .nothing(.alreadyMatches))
    }

    /// The case the rule exists for: a Bluetooth device offering 16 kHz and
    /// 44.1 kHz, playing 22.05 kHz material. Down to 16 would lose half the band.
    @Test func bluetoothGoesUpForMaterialAboveItsLowestRate() {
        let headphones: [ClosedRange<Int>] = [16000...16000, 44100...44100]
        #expect(
            RateSyncPolicy.decide(
                sourceRate: 22050, device: device(rate: 16000, supported: headphones))
                == .write(rate: 44100))
    }

    @Test func anUnknownDeviceRateIsWritten() {
        #expect(
            RateSyncPolicy.decide(sourceRate: 44100, device: device(rate: nil))
                == .write(rate: 44100))
    }

    @Test func aMatchingRateIsNotRewritten() {
        #expect(
            RateSyncPolicy.decide(sourceRate: 48000, device: device(rate: 48000))
                == .nothing(.alreadyMatches))
    }
}
