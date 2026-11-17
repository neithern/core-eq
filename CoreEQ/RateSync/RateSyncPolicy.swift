import Foundation

/// The rule that decides whether the output device may be reconfigured, and to
/// what.
///
/// Pure, so it can be exercised without a device or a player. The device is never
/// tuned below the material: see `OutputSampleRate.atOrAbove`.
enum RateSyncPolicy {
    /// The device as it is now.
    struct DeviceState: Equatable, Sendable {
        let rate: Int?
        let supportedRates: [ClosedRange<Int>]
        let isAggregate: Bool
    }

    enum Decision: Equatable {
        case write(rate: Int)
        case nothing(Reason)
    }

    enum Reason: Equatable {
        case aggregateOutput
        case noSupportedRates
        case alreadyMatches
    }

    static func decide(sourceRate: Int, device: DeviceState) -> Decision {
        guard !device.isAggregate else { return .nothing(.aggregateOutput) }

        guard let target = OutputSampleRate.atOrAbove(sourceRate, among: device.supportedRates)
        else { return .nothing(.noSupportedRates) }

        return device.rate == target ? .nothing(.alreadyMatches) : .write(rate: target)
    }
}
