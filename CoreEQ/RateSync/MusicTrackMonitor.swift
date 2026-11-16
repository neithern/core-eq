import Foundation
import os

/// Reports when Apple Music moves to another song.
///
/// The signal is the player own distributed notification rather than the log: it is
/// posted by Music itself, it names the song, and it arrives whether or not anything
/// is being written to disk. The log was tried first and could not say which of two
/// live decoders was audible.
@MainActor
final class MusicTrackMonitor {
    /// Called when the player moves to a different song, with what it announced.
    var onTrackChange: ((MusicPlayback) -> Void)?

    private let logger = Logger(
        subsystem: "com.andreypudov.coreeq", category: "RateSync")
    private var observer: (any NSObjectProtocol)?

    /// The last song seen, so a repeat report of the same one is not a change.
    ///
    /// The player posts on pause, on resume, and on seek as well, and every one of
    /// those would otherwise open a window and possibly reconfigure the hardware for
    /// a song that never changed.
    private var lastTitle: String?

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] notification in
            // Read the payload here: the dictionary is not sendable and the hop
            // below would be a data race on it.
            guard let playback = MusicPlayback(userInfo: notification.userInfo) else { return }
            MainActor.assumeIsolated { self?.received(playback) }
        }
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
        lastTitle = nil
    }

    private func received(_ playback: MusicPlayback) {
        guard playback.isPlaying else { return }

        guard let lastTitle else {
            // The first thing heard after starting is what is already playing.
            self.lastTitle = playback.title
            return
        }

        guard !MusicPlayback.namesMatch(lastTitle, playback.title) else { return }
        self.lastTitle = playback.title
        logger.notice("Apple Music reported a new playing track")
        onTrackChange?(playback)
    }
}
