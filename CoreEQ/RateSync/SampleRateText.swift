import Foundation

/// How a device rate is written in the window.
///
/// One decimal place, because the difference the feature is about is 44.1 against
/// 48 rather than 44100 against 48000. Rates arrive as whole hertz and are turned
/// into kilohertz only here, at the point of display.
enum SampleRateText {
    /// The rate as it is shown, e.g. "44.1 kHz".
    static func format(_ rate: Int) -> String {
        let kilohertz = Double(rate) / 1000
        // A whole number of kilohertz drops the decimal: "48 kHz" is what the
        // hardware menus say, and "48.0 kHz" beside it reads like a precision the
        // number does not have.
        if kilohertz == kilohertz.rounded() {
            return "\(Int(kilohertz)) kHz"
        }
        return String(format: "%.1f kHz", kilohertz)
    }
}
