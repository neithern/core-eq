import Combine
import Foundation
import os

/// Asks Apple Music for the format of the track it is playing.
///
/// This exists because the alternatives do not work. Music reports its decoders in
/// the system log, and those lines are accurate about *a* stream, but they never say
/// which stream is audible. Music decodes the next track before the current one ends
/// and keeps a pool of decoders it recycles across songs; measured over six hours,
/// 51% of tracks had more than one decoder reporting during them, so no rule for
/// picking one could be checked, let alone trusted.
///
/// The library knows. `sample rate of current track` exists for streamed songs as
/// well as local files, and does not follow the output device: with the device forced
/// to 96 kHz, a 44.1 kHz file still reported 44100 while the decoder line said the
/// same. That is what makes it a statement about the file rather than about us.
///
/// The cost is one system permission. Reading a property of another application is
/// automation, so macOS asks once and remembers the answer.
@MainActor
final class MusicTrackFormat {
    /// What Music says about the track it is playing.
    struct Format: Equatable, Sendable {
        /// The rate Music states, in whole hertz.
        ///
        /// Integer rather than `Double` for the same reason the device side is: a
        /// sample rate is a whole number of hertz, and the arithmetic that follows
        /// never needs a fraction.
        let sampleRate: Int
        /// The song the answer belongs to.
        ///
        /// Carried because the properties do not update atomically: at the instant a
        /// track change is announced the track object is already the new song while
        /// its `sample rate` can still hold the previous one. The identity is what
        /// detects that.
        ///
        /// An id rather than a name, because a name is not an identity: this library
        /// holds 64 duplicate titles in its first 500 tracks, the notification and
        /// the library do not always agree about the text, and a title can be
        /// truncated. Two different songs never share an id.
        let trackID: Int
        /// The song title, for the log only. Never compared.
        let trackName: String
    }

    private let logger = Logger(
        subsystem: "com.andreypudov.coreeq", category: "RateSync")

    /// Whether reading Music has been refused, so the app can say so once instead of
    /// logging the same refusal on every track — and so the setting can explain
    /// itself rather than appearing to do nothing.
    @Published private(set) var access: Access = .unknown

    enum Access: Equatable, Sendable {
        /// No query has been made yet, so nothing is known either way.
        case unknown
        /// A query was answered, which is the only proof of permission there is:
        /// macOS has no preflight for automation the way it does for the microphone.
        case granted
        /// macOS refused, or the user declined its prompt. Asking again does not
        /// bring the prompt back, so the only way out is System Settings.
        case refused
    }

    /// Asks for permission by asking for the thing permission is for.
    ///
    /// Automation has no request API: the prompt appears the first time a script is
    /// sent, and the answer becomes the stored decision. So this runs a real query
    /// and reads the outcome, which is also why enabling the feature for the first
    /// time has to be what triggers it — a prompt at launch would arrive with no
    /// explanation of what it is for.
    func requestAccess() async -> Bool {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.query())
            }
        }

        switch result {
        case .success:
            access = .granted
            return true
        case .failure(let reason):
            if case .permissionDenied = reason {
                access = .refused
                logger.error(
                    "Reading the track format needs permission to control Music: \(reason.description, privacy: .public)"
                )
            } else {
                // A script that failed for another reason says nothing about the
                // permission, so the state is left alone rather than called refused.
                logger.notice(
                    "Could not read the track format: \(reason.description, privacy: .public)")
            }
            return false
        }
    }

    /// The format Music states for the track it is playing, or `nil`.
    func fetch() async -> Format? {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.query())
            }
        }

        switch result {
        case .success(let format):
            access = .granted
            return format
        case .failure(let reason):
            if case .permissionDenied = reason {
                if access != .refused {
                    access = .refused
                    logger.error(
                        "Reading the track format needs permission to control Music: \(reason.description, privacy: .public)"
                    )
                }
            } else {
                logger.notice(
                    "Could not read the track format: \(reason.description, privacy: .public)")
            }
            return nil
        }
    }

    // MARK: - The script

    /// One property and one name, read-only.
    ///
    /// The name is requested alongside the rate because the two are what make the
    /// answer checkable. Nothing is played, paused, or added: a wrong answer can
    /// never move anything. `sample rate` arrives as an integer in hertz.
    nonisolated private static let script = """
        tell application "Music"
            if player state is not playing then return ""
            try
                return ((sample rate of current track) as string) ¬
                    & "\t" & ((id of current track) as string) ¬
                    & "\t" & (name of current track)
            on error
                return ""
            end try
        end tell
        """

    enum Failure: Error, Equatable {
        case permissionDenied
        case scriptFailed(String)
        case noAnswer

        var description: String {
            switch self {
            case .permissionDenied:
                "macOS is not allowing automation with Music"
            case .scriptFailed(let message):
                message
            case .noAnswer:
                "Music returned no sample rate"
            }
        }
    }

    /// Executes the script. Not `async`: the caller decides the queue.
    nonisolated static func query() -> Result<Format, Failure> {
        guard let scriptObject = NSAppleScript(source: script) else {
            return .failure(.scriptFailed("the script could not be compiled"))
        }

        var error: NSDictionary?
        let reply = scriptObject.executeAndReturnError(&error)

        if let error {
            // -1743 is "not authorized to send Apple events", the one failure worth
            // naming: it is a decision the user can reverse, and it recurs until they
            // do.
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 { return .failure(.permissionDenied) }
            let message = error[NSAppleScript.errorMessage] as? String ?? "error \(code)"
            return .failure(.scriptFailed(message))
        }

        let text = reply.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "44100\t10789\tTitle". Split without a limit: the title may itself
        // contain the separator, and only the first two fields are fixed.
        let parts = text.split(separator: "\t", omittingEmptySubsequences: false)
        // Read as an integer: Music states whole hertz, and a fractional value would
        // be a parse that went wrong rather than a rate to write.
        guard parts.count >= 3,
            let rate = Int(parts[0]), rate > 0,
            let identifier = Int(parts[1])
        else { return .failure(.noAnswer) }
        // The title is the remainder, rejoined in case it held a separator.
        let title = parts[2...].joined(separator: "\t")
        return .success(
            Format(sampleRate: rate, trackID: identifier, trackName: title))
    }
}
