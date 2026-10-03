/// Gets a push-to-talk recording ready for Whisper: decides whether anything was said
/// at all, and lifts quiet recordings to a level Whisper hears well.
public enum AudioConditioner {
    public struct Result: Sendable {
        public var samples: [Float]
        /// Loudest sample before any gain, 0…1.
        public var peak: Float
        /// Root-mean-square level before any gain, 0…1.
        public var rms: Float
        public var gain: Float
        /// Nothing louder than background hiss: don't bother transcribing.
        public var isSilent: Bool
    }

    /// Below this peak (about −40 dBFS) the recording is treated as silence. Whisper
    /// tends to invent words ("Thank you.") for silence, so this replaces its own
    /// no-speech filter, which also threw away short, quiet questions.
    public static let silencePeak: Float = 0.01
    /// Quiet recordings are raised so their peak reaches this…
    static let targetPeak: Float = 0.7
    /// …but never by more than this, so room noise isn't blown up.
    static let maxGain: Float = 12
    /// Silence put in front: Whisper often drops a first word that starts right at 0 s.
    public static let leadIn = 0.2

    public static func condition(_ samples: [Float], sampleRate: Double) -> Result {
        var peak: Float = 0
        var sumSquares: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            sumSquares += sample * sample
        }
        let rms = samples.isEmpty ? 0 : (sumSquares / Float(samples.count)).squareRoot()
        guard peak >= silencePeak else {
            return Result(samples: samples, peak: peak, rms: rms, gain: 1, isSilent: true)
        }
        let gain = min(max(targetPeak / peak, 1), maxGain)
        let padding = [Float](repeating: 0, count: Int(leadIn * sampleRate))
        let lifted = gain == 1 ? samples : samples.map { $0 * gain }
        return Result(samples: padding + lifted, peak: peak, rms: rms, gain: gain, isSilent: false)
    }
}
