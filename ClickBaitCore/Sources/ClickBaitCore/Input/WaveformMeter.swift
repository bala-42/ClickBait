import Foundation

/// The listening waveform's level and bar heights, after Clicky's (MIT)
/// `BlueCursorWaveformView`: five bars, 0.4/0.7/1/0.7/0.4 of the voice, on a gentle idle
/// pulse; the level rises at once and falls ×0.72 per 1024-sample buffer (~21.3 ms at
/// 48 kHz), here timed by the frame.
///
/// Loudness is on a decibel scale (−45 dB → 0, −15 dB → 1), not Clicky's RMS ×10.2: on this
/// Mac's microphone (2026-10-11, speech from the speakers: RMS median 0.025, 90th percentile
/// 0.068, room 0.007) Clicky's curve already pinned the middle bar at its top from RMS 0.035,
/// so a voice close to the mic would sit at full height instead of following the sound.
public enum WaveformMeter {
    public static let barProfile: [Double] = [0.4, 0.7, 1.0, 0.7, 0.4]
    public static let barWidth = 2.0
    public static let barSpacing = 2.0
    public static let barCornerRadius = 1.5
    public static let quietDecibels = -45.0
    public static let loudDecibels = -15.0
    static let decayPerBuffer = 0.72
    static let bufferSeconds = 1024.0 / 48_000

    /// How loud an RMS (0…1) is, 0…1 on the decibel scale.
    public static func loudness(rms: Double) -> Double {
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(max((decibels - quietDecibels) / (loudDecibels - quietDecibels), 0), 1)
    }

    /// The smoothed level after `dt` seconds, given the latest RMS (0…1).
    public static func level(after previous: Double, rms: Double, dt: Double) -> Double {
        let decayed = previous * pow(decayPerBuffer, max(dt, 0) / bufferSeconds)
        return max(loudness(rms: rms), decayed)
    }

    /// Bar `index`'s height (pt) for a smoothed `level` at `time` seconds: 3 pt, plus up to
    /// 10 pt of voice, plus a 0–1.5 pt idle pulse (none with Reduce Motion).
    public static func barHeight(index: Int, level: Double, time: Double, pulsing: Bool = true) -> Double {
        let phase = time * 3.6 + Double(index) * 0.35
        let eased = pow(min(max(level, 0), 1), 0.76)
        let reactive = eased * 10 * barProfile[min(max(index, 0), barProfile.count - 1)]
        let idle = pulsing ? (sin(phase) + 1) / 2 * 1.5 : 0
        return 3 + reactive + idle
    }
}
