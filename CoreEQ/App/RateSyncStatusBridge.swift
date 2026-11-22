import Combine
import Foundation

/// How reading the playing track is doing, where the Settings window can see it.
///
/// `RateSyncEngine` owns the permission state, and the Settings scene cannot be
/// handed the engine — it is built by SwiftUI on its own schedule. This carries the
/// one fact that window needs to explain a switch that appears to do nothing.
@MainActor
final class RateSyncStatusBridge: ObservableObject {
    static let shared = RateSyncStatusBridge()

    /// What is known about permission to read Music.
    @Published private(set) var access: MusicTrackFormat.Access = .unknown

    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    /// Called once, by whoever owns the engine.
    func follow(_ engine: RateSyncEngine) {
        cancellables.removeAll()
        engine.musicAccess
            .sink { [weak self] in self?.access = $0 }
            .store(in: &cancellables)
    }
}
