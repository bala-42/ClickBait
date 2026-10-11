import Foundation

/// The listening waveform's level and bar heights, after Clicky's (MIT)
/// `BlueCursorWaveformView`: the microphone's RMS boosted ×10.2 (capped at 1), rising at
/// once and falling by ×0.72 per 1024-sample buffer (~21.3 ms at 48 kHz) — here per second
/// of frame time, since ClickBait reads the level once a frame; five bars, 0.4/0.7/1/0.7/0.4
/// of the voice, on a gentle idle pulse.
public enum WaveformMeter {
    public static let barProfile: [Double] = [0.4, 0.7, 1.0, 0.7, 0.4]
    public static let barWidth = 2.0
    public static let barSpacing = 2.0
    public static let barCornerRadius = 1.5
    static let boost = 10.2
    static let decayPerBuffer = 0.72
    static let bufferSeconds = 1024.0 / 48_000

    /// The smoothed level after `dt` seconds, given the latest RMS (0…1).
    public static func level(after previous: Double, rms: Double, dt: Double) -> Double {
        let boosted = min(max(rms * boost, 0), 1)
        let decayed = previous * pow(decayPerBuffer, max(dt, 0) / bufferSeconds)
        return max(boosted, decayed)
    }

    /// Bar `index`'s height (pt) for a smoothed `level` at `time` seconds: 3 pt, plus up to
    /// 10 pt of voice, plus a 0–1.5 pt idle pulse (none with Reduce Motion).
    public static func barHeight(index: Int, level: Double, time: Double, pulsing: Bool = true) -> Double {
        let phase = time * 3.6 + Double(index) * 0.35
        let normalized = max(level - 0.008, 0)
        let eased = pow(min(normalized * 2.85, 1), 0.76)
        let reactive = eased * 10 * barProfile[min(max(index, 0), barProfile.count - 1)]
        let idle = pulsing ? (sin(phase) + 1) / 2 * 1.5 : 0
        return 3 + reactive + idle
    }
}
