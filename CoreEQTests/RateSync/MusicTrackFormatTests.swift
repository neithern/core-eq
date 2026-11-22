import Foundation
import Testing

/// Reading what Music says about the song it is playing.
///
/// The script answers "44100\t10789\tTitle", and the parse is where a wrong answer
/// would come from: a rate read off the wrong field, or an identity that cannot tell
/// two songs apart.
struct MusicTrackFormatTests {

    // MARK: - The identity

    /// The reason an id is carried at all: a name is not an identity. This library
    /// holds 64 duplicate titles in its first 500 tracks, so a name-based check would
    /// accept the wrong song.
    @Test func twoSongsWithTheSameTitleHaveDifferentIdentities() {
        let first = MusicTrackFormat.Format(sampleRate: 44100, trackID: 10789, trackName: "Intro")
        let second = MusicTrackFormat.Format(sampleRate: 96000, trackID: 11141, trackName: "Intro")

        #expect(first.trackID != second.trackID)
        #expect(first != second)
    }

    @Test func theSameSongIsEqual() {
        let first = MusicTrackFormat.Format(sampleRate: 44100, trackID: 10789, trackName: "Intro")
        let second = MusicTrackFormat.Format(sampleRate: 44100, trackID: 10789, trackName: "Intro")

        #expect(first == second)
    }

    /// A song whose rate was re-read at a different number is still the same song,
    /// which is what the stale-read check relies on.
    @Test func identitySurvivesADifferentReading() {
        let before = MusicTrackFormat.Format(sampleRate: 44100, trackID: 10789, trackName: "Intro")
        let after = MusicTrackFormat.Format(sampleRate: 48000, trackID: 10789, trackName: "Intro")

        #expect(before.trackID == after.trackID)
    }
}
