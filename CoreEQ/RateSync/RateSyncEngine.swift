import Combine
import CoreAudio
import Foundation
import os

/// Keeps the output device at the sample rate of the track Apple Music is playing,
/// and publishes the device format for the window header.
///
/// It is deliberately not part of `AudioEngine`. The engine job is the audio path;
/// this is a system-output policy that runs alongside it, and the engine already
/// treats a device rate change as an external event it has to rebuild around. That
/// keeps the realtime path untouched and makes the feature fail into "no change"
/// rather than into silence.
///
/// ## Why it asks Music instead of reading the log
///
/// The obvious source is Core Audio own log, where every decoder states its input
/// format. It is accurate about *a* stream and silent about *which* is audible.
/// Music decodes the next track before the current one ends and recycles decoders
/// across songs, so at a natural boundary two decoders report within milliseconds of
/// each other. Measured over six hours, 51% of tracks had more than one decoder
/// reporting during them; every rule tried for choosing one between them scored
/// between 44% and 69% against the only ground truth available. The log simply does
/// not contain the answer.
///
/// The library does. `sample rate of current track` covers local files, streamed
/// songs and Atmos alike, and it does not follow the device: with the hardware forced
/// to 96 kHz a 44.1 kHz file still reported 44100.
///
/// ## One window, one write
///
/// A change is considered only inside a five second window opened by a track change,
/// by the app starting, or by the output device changing. After the window shuts the
/// song is left alone until the next one, so nothing can retune the output under
/// music that is already playing.
@MainActor
final class RateSyncEngine: ObservableObject {
    /// The output device nominal rate, for the header. `nil` when there is no
    /// device or Core Audio cannot answer, never a default that looks plausible.
    @Published private(set) var outputRate: Int?

    /// The output stream physical bit depth, for the line beside it.
    ///
    /// The hardware depth, not the source: the header states what the device is
    /// doing, and a 16-bit source on a 24-bit-only device correctly reads 24 bit.
    @Published private(set) var outputBitDepth: Int?

    private let settings: SettingsStore
    private let trackFormat = MusicTrackFormat()

    /// Permission to read Music, published so the Settings window can explain a
    /// switch that would otherwise look like it does nothing.
    var musicAccess: AnyPublisher<MusicTrackFormat.Access, Never> {
        trackFormat.$access.eraseToAnyPublisher()
    }
    private let trackMonitor = MusicTrackMonitor()
    private let logger = Logger(
        subsystem: "com.andreypudov.coreeq", category: "RateSync")

    private var isStarted = false
    private var isSyncEnabled = false
    private var settingsObserver: (any NSObjectProtocol)?

    /// The device everything is written to. The UID is kept too, so a repeat report
    /// of the same device does not tear down its listener.
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var outputDeviceUID: String?
    private var rateListener: AudioObjectPropertyListenerBlock?

    /// Which track change this is.
    ///
    /// Stands in for the five second timer the feature used to run on. The timer
    /// existed to stop a player that kept logging from retuning the output mid-song;
    /// with the rate now read from Music once per track change, there is no such
    /// stream of reports, and what is left to guard against is an *answer arriving
    /// late* — a query that took so long the song it describes has already ended.
    ///
    /// A counter answers that exactly: every change bumps it, and a result computed
    /// for an older value is discarded rather than applied to the wrong song. It has
    /// no timer to cancel, which is what produced the stale-close bugs the timer did
    /// — `DispatchWorkItem.cancel()` does not remove a block from the queue, so a
    /// retired window still ran its close.
    private var trackGeneration = 0

    /// Whether this track change has already been acted on.
    ///
    /// One write per change is deliberate. Letting a change revise its answer was
    /// tried and produced two reconfigurations where the second was wrong — worse
    /// than one answer that is merely stale.
    private var hasActedInThisGeneration = false

    /// The id of the song Music last answered for.
    ///
    /// The guard against acting on a stale read: at a track change the track object
    /// has already swapped while its properties can still hold the previous song, so
    /// a read whose id has not changed is a read of the song that just ended.
    private var lastAcceptedTrackID: Int?

    /// The previous answer, for the settle check.
    ///
    /// Two reads that agree are a read of a settled track. A single read cannot tell
    /// "the rate is right" from "the rate has not been updated yet", which is why the
    /// first one after a change is never acted on.
    private var lastReading: MusicTrackFormat.Format?

    /// How many times the format question has been asked for the current window.
    private var attemptsThisGeneration = 0

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observeSettings()

        isSyncEnabled = settings.syncsOutputSampleRate
        if isSyncEnabled {
            startTracking()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        stopTracking()
        removeSettingsObserver()
        removeRateListener()
        outputDeviceID = AudioObjectID(kAudioObjectUnknown)
        outputDeviceUID = nil
        updateOutputRate(nil)
        updateOutputBitDepth(nil)
    }

    /// Called by the app delegate with the device the system is actually using.
    ///
    /// The value is the one `OutputDeviceFollower` emitted, never re-read from the
    /// device list: a subscriber that reaches back sees the device being replaced.
    func setOutputDeviceUID(_ uid: String?) {
        guard uid != outputDeviceUID else { return }
        outputDeviceUID = uid
        removeRateListener()

        guard let uid, let deviceID = OutputDeviceFormat.deviceID(forPersistentID: uid) else {
            outputDeviceID = AudioObjectID(kAudioObjectUnknown)
            updateOutputRate(nil)
            updateOutputBitDepth(nil)
            return
        }

        outputDeviceID = deviceID
        installRateListener(on: deviceID)
        readOutputFormat()

        // A newly chosen device is a moment the output may be matched to the song,
        // for the same reason a track change is: the user just changed something,
        // and waiting for the next track would leave the new device at whatever
        // rate it happened to be running.
        beginGeneration()
        askMusic()
    }

    // MARK: - Settings

    private func observeSettings() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    private func removeSettingsObserver() {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        settingsObserver = nil
    }

    private func settingsChanged() {
        guard isStarted else { return }
        let isEnabled = settings.syncsOutputSampleRate
        guard isEnabled != isSyncEnabled else { return }

        isSyncEnabled = isEnabled
        logger.notice("Sample rate following \(isEnabled ? "on" : "off", privacy: .public)")
        if isEnabled {
            startTracking()
        } else {
            stopTracking()
        }
    }

    // MARK: - Tracking

    private func startTracking() {
        beginGeneration()
        trackMonitor.onTrackChange = { [weak self] playback in
            self?.trackChanged()
        }
        trackMonitor.start()

        // The app starting is the other moment a write is allowed, and the song may
        // already be halfway through.
        askMusic()

        // Asking Music is what asks for permission to ask Music: automation has no
        // request API, so the prompt appears on the first script and the answer
        // becomes the stored decision. Doing it here rather than at launch is the
        // point — the prompt arrives when the user has just turned this on, so it
        // has an explanation, instead of greeting them on a cold start.
        if trackFormat.access == .unknown {
            Task { [weak self] in
                guard let self else { return }
                _ = await self.trackFormat.requestAccess()
                self.logAccess()
            }
        } else {
            logAccess()
        }
    }

    /// Says what happened, because a feature that silently does nothing is worse
    /// than one that is switched off.
    private func logAccess() {
        switch trackFormat.access {
        case .granted:
            logger.notice("Permission to read Music is granted")
        case .refused:
            logger.error(
                "Permission to read Music was refused; enable it in System Settings > Privacy & Security > Automation"
            )
        case .unknown:
            break
        }
    }

    private func stopTracking() {
        trackMonitor.stop()
        // Retires whatever was in flight: a result computed for this generation must
        // not be applied after the feature has been turned off.
        trackGeneration += 1
        hasActedInThisGeneration = false
        attemptsThisGeneration = 0
    }

    /// A new track: retire whatever was in flight and ask what this one is.
    private func trackChanged() {
        logger.notice("Track changed")
        beginGeneration()
        askMusic()
    }

    // MARK: - Asking Music

    /// Asks Music for the playing track format, and checks the answer belongs to the
    /// track that was announced.
    ///
    /// The check is the whole point, and it is subtler than "did the id change".
    ///
    /// Measured on this Mac, immediately after `next track`:
    ///
    /// ```
    /// +  0 ms   48000  11156   <- new song id, previous song rate
    /// + 30 ms   44100  10729   <- both settled
    /// ```
    ///
    /// The id leads the rate, so an id that has changed proves nothing about the
    /// rate beside it — acting on that first read writes the previous song rate,
    /// which is exactly the failure this feature kept having. What does prove it is
    /// agreement: two reads that state the same pair are a read of a settled track.
    /// It settles in about 30 ms, so one extra query is a cheap price.
    private func askMusic() {
        guard isSyncEnabled, !hasActedInThisGeneration else { return }
        guard outputDeviceID != kAudioObjectUnknown else { return }
        guard attemptsThisGeneration < RateSyncEngine.maxAttempts else {
            logger.notice("Gave up asking Music; leaving the device alone")
            return
        }
        attemptsThisGeneration += 1

        let previous = lastReading
        let previousID = lastAcceptedTrackID
        Task { [weak self] in
            guard let self else { return }
            let format = await self.trackFormat.fetch()

            // The world may have moved while the answer was in flight.
            guard self.isSyncEnabled, !self.hasActedInThisGeneration else {
                return
            }

            guard let format else {
                self.logger.notice("Music had no answer; asking again")
                self.askMusic()
                return
            }

            // Nothing has changed since the last read, so this one describes the
            // same moment rather than a settled track.
            if let previous,
                previous.trackID == format.trackID,
                previous.sampleRate == format.sampleRate
            {
                self.hasActedInThisGeneration = true
                self.lastAcceptedTrackID = format.trackID
                self.lastReading = format
                self.logger.notice(
                    "Music says \(format.sampleRate, privacy: .public) Hz for track \(format.trackID, privacy: .public) \"\(format.trackName, privacy: .public)\""
                )
                self.apply(rate: format.sampleRate)
                return
            }

            // The first read, or one that moved: remember it and look again rather
            // than trusting a pair that is still settling.
            self.lastReading = format

            let reason: String
            if let previousID, format.trackID == previousID {
                reason = "Music still reports track \(format.trackID), the song that just ended"
            } else {
                reason = "Waiting for the rate to settle at \(format.sampleRate) Hz"
            }
            self.logger.notice("\(reason, privacy: .public); asking again")

            // Straight back to the top, with no delay: the read itself is the
            // interval. One round trip measured 27–72 ms, median 50 ms — longer
            // than any pause worth adding, so a wait on top of it would only put
            // the second read further from the change it is trying to catch.
            self.askMusic()
        }
    }

    // MARK: - The track change

    /// Begins a new track change: nothing from before it may be applied now.
    private func beginGeneration() {
        trackGeneration += 1
        hasActedInThisGeneration = false
        attemptsThisGeneration = 0
        // The settle check compares two reads of *this* track. Carrying the previous
        // one across would make the first read of the new track look settled against
        // a song that has already ended.
        lastReading = nil

    }

    // MARK: - Writing the device

    /// Runs the judgement through the policy and writes what it says.
    ///
    /// The rate comes from Music, which takes about 50 ms and is the only source
    /// that names the song it is describing. Nothing else is written: the bit depth
    /// is left to the device, because nothing in the log states it reliably enough
    /// to justify reconfiguring the hardware for it.
    private func apply(rate: Int) {
        let device = deviceState()

        switch RateSyncPolicy.decide(sourceRate: rate, device: device) {
        case .write(let target):
            write(rate: target)

        case .nothing(let reason):
            logger.notice(
                "Left the rate alone: \(String(describing: reason), privacy: .public)")
        }
    }

    /// The device as it is now.
    private func deviceState() -> RateSyncPolicy.DeviceState {
        RateSyncPolicy.DeviceState(
            rate: OutputDeviceFormat.rate(of: outputDeviceID),
            supportedRates: OutputDeviceFormat.supportedRates(of: outputDeviceID),
            isAggregate: OutputDeviceFormat.isAggregate(outputDeviceID))
    }

    /// Writes the rate, then reports what it means to have written.
    ///
    /// The write is asynchronous. `AudioObjectSetPropertyData` returns `noErr` before
    /// the hardware has switched, and a read taken straight afterwards still returns
    /// the *previous* rate — measured here, writing 48 kHz on the Studio Display read
    /// back 44.1 kHz for several hundred milliseconds. So the target is what gets
    /// published, and the read-back is not used to judge the write.
    private func write(rate: Int) {
        if OutputDeviceFormat.rate(of: outputDeviceID) != rate {
            _ = OutputDeviceFormat.setRate(rate, of: outputDeviceID)
        }

        updateOutputRate(rate)
        updateOutputBitDepth(OutputDeviceFormat.bitDepth(of: outputDeviceID))

        let name = OutputDeviceFormat.name(of: outputDeviceID) ?? "the output device"
        logger.notice(
            "Set \(name, privacy: .public) to \(rate, privacy: .public) Hz for the playing track"
        )
    }

    // MARK: - Device rate

    private func installRateListener(on deviceID: AudioObjectID) {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.readOutputFormat() }
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
            rateListener = block
        } else {
            logger.error("Failed to observe the sample rate of \(deviceID)")
        }
    }

    private func removeRateListener() {
        if let rateListener, outputDeviceID != kAudioObjectUnknown {
            var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(
                outputDeviceID, &address, .main, rateListener)
        }
        rateListener = nil
    }

    /// Reads both halves of the device format together, so the header cannot
    /// describe two different moments.
    private func readOutputFormat() {
        guard outputDeviceID != kAudioObjectUnknown else {
            updateOutputRate(nil)
            updateOutputBitDepth(nil)
            return
        }
        updateOutputRate(OutputDeviceFormat.rate(of: outputDeviceID))
        updateOutputBitDepth(OutputDeviceFormat.bitDepth(of: outputDeviceID))
    }

    private func updateOutputRate(_ rate: Int?) {
        guard outputRate != rate else { return }
        outputRate = rate
    }

    private func updateOutputBitDepth(_ bitDepth: Int?) {
        guard outputBitDepth != bitDepth else { return }
        outputBitDepth = bitDepth
    }

    private func propertyAddress(
        _ selector: AudioObjectPropertySelector
    )
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - Constants

    /// How long to wait before asking Music again.
    ///
    /// The wait exists only to let the answer settle between two reads; it is not a
    /// timeout. Most changes are already settled by the time the first read returns,
    /// so a short wait costs almost nothing when the answer is ready and only matters
    /// when it is not. Measured, the pair settles somewhere between 0 and 800 ms —
    /// which is why the rule is "two reads that agree" rather than a fixed delay, and
    /// why the delay is kept short: it is the floor of each retry, not its bound.
    ///
    /// How many times to ask.
    ///
    /// There is no delay between attempts: a read is a round trip to another process
    /// and costs 27–72 ms on its own, so the loop is already paced by the work. Ten
    /// attempts therefore span roughly a quarter of a second — long enough for the
    /// slowest settle measured, short enough that a property which is not going to
    /// answer is abandoned rather than waited on. The caller gives up rather than
    /// writing a guess.
    static let maxAttempts = 10

    isolated deinit {
        stop()
    }
}
