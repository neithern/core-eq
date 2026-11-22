import Foundation

/// What Apple Music is playing, as the player itself reports it.
///
/// The player posts a distributed notification whenever its state changes, and the
/// user info carries the song. The first notification after the app starts is the
/// answer to "what is already playing", not a change: it is recorded so a later
/// comparison has something to compare against, but it does not count as a switch.
struct MusicPlayback: Equatable, Sendable {
    /// The song title the player announced.
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool

    init(title: String, artist: String, album: String, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
    }

    /// Reads the notification payload.
    ///
    /// Built before any concurrency hop, because the user-info dictionary is not
    /// `Sendable` and carrying it across an isolation boundary is a data race the
    /// compiler is right to refuse.
    init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return nil }
        guard let title = userInfo["Name"] as? String, !title.isEmpty else { return nil }
        self.title = title
        self.artist = userInfo["Artist"] as? String ?? ""
        self.album = userInfo["Album"] as? String ?? ""
        self.isPlaying = (userInfo["Player State"] as? String) == "Playing"
    }

    /// Whether two reports name the same song.
    ///
    /// Used only to drop repeats from the player, which posts on pause, resume and
    /// seek as well as on a track change. The answer that decides whether to write is
    /// checked by track id instead — a name cannot tell two songs apart, and this
    /// library holds 64 duplicate titles in its first 500 tracks.
    static func namesMatch(_ first: String, _ second: String) -> Bool {
        let left = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = second.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.hasPrefix(right) || right.hasPrefix(left)
    }
}
