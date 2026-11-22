import Combine
import Foundation

/// The output format the rate following is publishing, where the window can see it.
///
/// `RateSyncEngine` is owned by the app delegate; the main window is built by
/// SwiftUI on its own schedule and cannot be handed it. This carries the two facts
/// the header needs — the device rate and its bit depth — and nothing else.
///
/// The values are the device's, not the source's. A 16-bit track on a 24-bit-only
/// device correctly reads 24 bit, because that is the depth the hardware delivers,
/// and the header is describing the output.
@MainActor
final class OutputFormatBridge: ObservableObject {
    static let shared = OutputFormatBridge()

    @Published private(set) var rate: Int?
    @Published private(set) var bitDepth: Int?

    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    /// Called once, by whoever owns the engine.
    func follow(_ engine: RateSyncEngine) {
        cancellables.removeAll()
        engine.$outputRate
            .sink { [weak self] in self?.rate = $0 }
            .store(in: &cancellables)
        engine.$outputBitDepth
            .sink { [weak self] in self?.bitDepth = $0 }
            .store(in: &cancellables)
    }

    /// The format as one line, e.g. "48 kHz · 24 bit".
    ///
    /// `nil` when the device would not say, so the line disappears rather than
    /// showing a plausible default no hardware confirmed.
    var text: String? {
        var parts: [String] = []
        if let rate { parts.append(SampleRateText.format(rate)) }
        if let bitDepth { parts.append("\(bitDepth) bit") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
