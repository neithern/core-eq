import Foundation
import Testing

/// Whether Music answer describes the song the player announced.
///
/// This is the check that makes the whole design safe. At the instant a track change
/// is announced the track object has already been swapped but its `sample rate` can
/// still hold the previous song value. Acting on that first answer writes the wrong
/// rate — which is exactly the bug this rule exists to catch.
struct MusicPlaybackTests {

    @Test func readsTheSongFromTheNotification() {
        let playback = MusicPlayback(userInfo: [
            "Name": "Hotel California",
            "Artist": "Eagles",
            "Album": "Hell Freezes Over",
            "Player State": "Playing",
        ])

        #expect(playback?.title == "Hotel California")
        #expect(playback?.artist == "Eagles")
        #expect(playback?.isPlaying == true)
    }

    @Test func aPausedReportIsStillReadable() {
        let playback = MusicPlayback(userInfo: [
            "Name": "Hotel California",
            "Player State": "Paused",
        ])

        #expect(playback?.isPlaying == false)
    }

    @Test func aNotificationWithoutASongIsIgnored() {
        #expect(MusicPlayback(userInfo: ["Player State": "Playing"]) == nil)
        #expect(MusicPlayback(userInfo: ["Name": ""]) == nil)
        #expect(MusicPlayback(userInfo: nil) == nil)
    }

    // MARK: - Matching an answer to an announcement

    @Test func theSameNameMatches() {
        #expect(MusicPlayback.namesMatch("Dance Monkey", "Dance Monkey"))
    }

    @Test func caseAndSurroundingSpaceDoNotMatter() {
        #expect(MusicPlayback.namesMatch("Dance Monkey", " dance monkey "))
    }

    /// A wrong answer is what the check is for: the previous song name must not
    /// pass as the new one.
    @Test func aDifferentSongDoesNotMatch() {
        #expect(!MusicPlayback.namesMatch("Hotel California", "Dance Monkey"))
    }

    @Test func anEmptyNameNeverMatches() {
        #expect(!MusicPlayback.namesMatch("", "Dance Monkey"))
        #expect(!MusicPlayback.namesMatch("Dance Monkey", ""))
    }

    /// The answer is allowed to be longer than the announcement: the notification
    /// and the library do not always agree about the suffix.
    @Test func aLongerAnswerMatchesOnItsPrefix() {
        #expect(MusicPlayback.namesMatch("Dance Monkey (feat. Someone)", "Dance Monkey"))
    }
}
