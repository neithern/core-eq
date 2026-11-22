import CoreAudio
import Foundation

/// Reading and writing the output device format.
///
/// Every call that reaches the hardware for this feature lives here, which is why
/// this file sits beside the engine rather than being folded into `AudioDevices`:
/// that type is the app general device inventory, and this is the one policy that
/// reconfigures the output.
///
/// Not tested, by the same rule that keeps `AudioDevices` out of the test target:
/// it is a thin wrapper over Core Audio calls, and what is worth testing is the
/// decision made from its answers, which is `RateSyncPolicy`.
enum OutputDeviceFormat {

    // MARK: - Reading

    /// The rate the device is running, in whole hertz.
    ///
    /// Core Audio states it as `Float64` because the property system has no integer
    /// type, but every rate hardware or a file names is an integer — this Mac offers
    /// 44100, 48000, 88200 and 96000 and nothing between. Converting here keeps the
    /// arithmetic above on integers, where a rate cannot pick up a fractional part.
    ///
    /// `nil` when the device will not say, which has to stay distinguishable from
    /// "it is at zero".
    static func rate(of deviceID: AudioDeviceID) -> Int? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, value > 0 else { return nil }
        return Int(value.rounded())
    }

    /// The rate ranges the device offers, as inclusive closed ranges of whole hertz.
    ///
    /// Devices answer with ranges rather than a list, and a rate inside a range is
    /// runnable. An empty array means the device refused to answer, which the policy
    /// treats differently from "it can do nothing".
    static func supportedRates(of deviceID: AudioDeviceID) -> [ClosedRange<Int>] {
        var address = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr
        else { return [] }
        return ranges.map {
            Int($0.mMinimum.rounded())...Int($0.mMaximum.rounded())
        }
    }

    /// The bit depth the device is delivering, from its first output stream.
    ///
    /// `nil` when there are no output streams: reporting a plausible default would
    /// put a number in the window that no hardware confirmed.
    static func bitDepth(of deviceID: AudioDeviceID) -> Int? {
        formats(of: deviceID).first.map { Int($0.mBitsPerChannel) }
    }

    /// The device that currently carries a persistent identifier.
    ///
    /// The identifier survives reboots; the `AudioDeviceID` does not, so anything
    /// holding a device across launches has to resolve it back. `nil` means the
    /// device is not connected now.
    static func deviceID(forPersistentID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return nil }

        return devices.first { persistentID(of: $0) == uid }
    }

    /// Whether the device is an aggregate, which this feature never reconfigures.
    static func isAggregate(_ deviceID: AudioDeviceID) -> Bool {
        transportType(of: deviceID) == kAudioDeviceTransportTypeAggregate
    }

    /// The device own name, for the log.
    static func name(of deviceID: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr
        else { return nil }
        return name?.takeRetainedValue() as String?
    }

    // MARK: - Writing

    /// Sets the device rate. Whether Core Audio accepted the request.
    ///
    /// `noErr` means the request was taken, not that the hardware has switched: a
    /// read taken straight afterwards still returns the previous rate for several
    /// hundred milliseconds, measured on this Mac. Callers report the target rather
    /// than the read-back, or the window and the next decision both believe a change
    /// happened that has not.
    @discardableResult
    static func setRate(_ rate: Int, of deviceID: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        // Core Audio takes the rate as Float64; the integer is the same number.
        var value = Float64(rate)
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        return status == noErr
    }

    // MARK: - Private

    private static func address(
        _ selector: AudioObjectPropertySelector
    )
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func persistentID(of deviceID: AudioDeviceID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr
        else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
        else { return 0 }
        return value
    }

    /// The output streams of the device.
    private static func outputStreams(of deviceID: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams) == noErr
        else { return [] }
        return streams
    }

    /// Every physical format the device output streams support.
    private static func formats(of deviceID: AudioDeviceID) -> [AudioStreamBasicDescription] {
        outputStreams(of: deviceID).flatMap { formats(ofStream: $0) }
    }

    private static func formats(ofStream stream: AudioStreamID) -> [AudioStreamBasicDescription] {
        var selector = address(kAudioStreamPropertyAvailablePhysicalFormats)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(stream, &selector, 0, nil, &size) == noErr,
            size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioStreamRangedDescription>.size
        var descriptions = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(), count: count)
        guard AudioObjectGetPropertyData(stream, &selector, 0, nil, &size, &descriptions) == noErr
        else { return [] }

        return descriptions.map { $0.mFormat }
    }
}
