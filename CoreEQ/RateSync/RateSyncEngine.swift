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

    /// The id of the song Music last answered for.
    ///
    /// The guard against acting on a stale read: at a track change the track object
    /// has already swapped while its properties can still hold the previous song, so
    /// a read whose id has not changed is a read of the song that just ended.
    private var lastAcceptedTrackID: Int?

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
        //
        // Without a pause: a pause is for a switch in the middle of a song, where the
        // device going away would be heard. A device the user has just chosen has no
        // audio to interrupt yet, and pausing here would be a silence with no cause.
        beginGeneration()
        matchDeviceToThePlayingTrack()
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
        // already be halfway through. Same reasoning as a device change: nothing is
        // being interrupted, so nothing is paused.
        matchDeviceToThePlayingTrack()

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
    }

    /// A new track: pause, read, switch, rebuild, resume.
    ///
    /// Pausing first is what makes the switch silent. The device is unavailable for
    /// about a third of a second while it renegotiates, and without a pause that
    /// third of a second is a click in the middle of a song. With it, the gap is
    /// deliberate: measured, the audio is stopped for about 47 ms around the switch.
    ///
    /// Most of the cost of the pause is not the pause. A `play` command takes about
    /// 275 ms to return, and only 47 ms of that is audio actually stopped — the rest
    /// is the round trip. That is why the pause happens on every track change rather
    /// than only when the rate differs: reading the rate first to decide would cost
    /// about as much as the pause it would save.
    private func trackChanged() {
        logger.notice("Track changed")
        beginGeneration()

        guard isSyncEnabled else { return }
        Task { await switchToTheNewTrack() }
    }

    /// Matches the device to whatever is playing, without pausing.
    ///
    /// For the moments where no audio is being interrupted: the app starting, or the
    /// user choosing a different output. A pause there would be a silence with no
    /// cause, and the switch itself has nothing to hide behind.
    private func matchDeviceToThePlayingTrack() {
        let generation = trackGeneration
        Task { [weak self] in
            guard let self, let format = await self.settledFormat() else { return }
            guard self.isSyncEnabled, self.trackGeneration == generation else { return }

            self.lastAcceptedTrackID = format.trackID
            self.logger.notice(
                "Music says \(format.sampleRate, privacy: .public) Hz for track \(format.trackID, privacy: .public) \"\(format.trackName, privacy: .public)\""
            )
            self.apply(rate: format.sampleRate)
        }
    }
    /// The whole sequence for one track change.
    private func switchToTheNewTrack() async {
        let generation = trackGeneration

        let paused = await trackMonitor.suppressingOwnCommands {
            await trackFormat.pause()
        }
        logger.notice("Paused Music for the switch: \(paused, privacy: .public)")

        // Whatever happens below, the player is put back. Without this a failed read
        // or a refused write would leave Music paused with nothing to resume it.
        defer {
            Task {
                await trackMonitor.suppressingOwnCommands { await trackFormat.play() }
                logger.notice("Resumed Music")
            }
        }

        guard let format = await settledFormat() else {
            logger.notice("No settled format; leaving the device alone")
            return
        }
        guard trackGeneration == generation else { return }

        logger.notice(
            "Music says \(format.sampleRate, privacy: .public) Hz for track \(format.trackID, privacy: .public) \"\(format.trackName, privacy: .public)\""
        )
        lastAcceptedTrackID = format.trackID
        apply(rate: format.sampleRate)
    }

    /// Reads until two answers agree, which is what tells a settled track from one
    /// that is still being prepared.
    ///
    /// The id leads the rate by about 30 ms: immediately after a change the track
    /// object is already the new song while its rate still belongs to the old one.
    /// Agreement is what rules that out.
    private func settledFormat() async -> MusicTrackFormat.Format? {
        var previous: MusicTrackFormat.Format?
        var failures = 0

        for _ in 0..<RateSyncEngine.maxAttempts {
            guard let format = await trackFormat.fetch() else {
                failures += 1
                // A read that fails is a player that has not caught up: it is still
                // loading the track, and asking again immediately only spends the
                // attempts without giving it time. Measured, ten immediate retries
                // burned the whole budget in 500 ms and gave up while Music was still
                // opening the song. Backing off turns the same budget into a window
                // the player can finish in.
                if failures >= RateSyncEngine.maxFailedReads {
                    logger.notice(
                        "Music had no answer after \(failures, privacy: .public) reads; giving up")
                    return nil
                }
                await Self.backOff(afterFailures: failures)
                continue
            }
            failures = 0

            if let previous,
                previous.trackID == format.trackID,
                previous.sampleRate == format.sampleRate
            {
                return format
            }
            previous = format
        }
        return nil
    }

    /// Waits before the next read, longer after each failure.
    ///
    /// The wait grows with the number of failures because the usual cause is a player
    /// that needs time, and a fixed short interval would spend the whole budget before
    /// it had any. The cap keeps the total inside the window the switch can afford.
    private static func backOff(afterFailures failures: Int) async {
        let base = RateSyncEngine.retryBackoff
        let wait = min(base * Double(failures), RateSyncEngine.maxBackoff)
        try? await Task.sleep(for: .seconds(wait))
    }

    // MARK: - The track change

    /// Begins a new track change: nothing from before it may be applied now.
    private func beginGeneration() {
        trackGeneration += 1
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
        // No rebuild here, deliberately.
        //
        // The engine rebuilds from its own rate listener, and measurement showed
        // that is the rebuild audio actually returns from: the eager one landed in
        // the same millisecond as the write, while the device was still
        // renegotiating, and audio did not start again until the listener rebuilt
        // about two seconds later. Rebuilding here only tore down a path that was
        // about to be torn down again.

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

    /// How many reads may fail before the switch gives up on this track.
    ///
    /// A failed read is not the same as a read that disagrees: disagreement is the
    /// normal course of a rate that is settling, while a failure means Music would
    /// not name the track at all. Three is enough to cover a slow load and short
    /// enough that a player which is not going to answer does not hold the switch.
    static let maxFailedReads = 3

    /// How long to wait after a failed read, multiplied by the number of failures.
    ///
    /// A hundred milliseconds, then two, then three: the whole budget becomes about
    /// half a second of real waiting, which is what a loading track needs.
    static let retryBackoff: TimeInterval = 0.1

    /// The longest a single wait may become.
    static let maxBackoff: TimeInterval = 0.3

    isolated deinit {
        stop()
    }
}
