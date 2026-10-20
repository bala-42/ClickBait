import Foundation

/// The notch's character (user's choice, 2026-10-21): a soft pearl bean with kaomoji eyes and
/// a small drawn mouth, wearing ClickBait's state colours as a glow. A wide squircle, a
/// little flatter at the bottom.
/// Each mood has a few eye pairs; a new one is picked whenever the mood changes, avoiding the
/// last one shown.
///
///     let eyes = Bean.eyes(for: .thinking, avoiding: "• •")  // e.g. "◔ ◔"
public enum Bean {
    public enum Mood: String, CaseIterable, Sendable {
        /// Following along, nothing happening.
        case idle
        /// The microphone is on (asking or dictating).
        case listening
        /// The model is working out an answer.
        case thinking
        /// A command is running.
        case working
        /// A command finished, or a hello.
        case happy
        /// Something went wrong.
        case error
        /// Nothing has happened for a while, or the battery is nearly empty.
        case sleepy
        /// The processor is flat out: trembling eyes and a sweat drop.
        case panicked
        /// The Mac is running hot: flushed cheeks.
        case warm
        /// The battery is low: heavy eyelids.
        case tired
    }

    /// The mouth drawn under the eyes.
    public enum Mouth: Sendable, Equatable {
        /// A small upward curve.
        case smile
        /// A wide open curve.
        case grin
        /// A little "o".
        case open
        /// A short flat line.
        case flat
        /// A small downward curve.
        case frown
    }

    /// The eye pairs, one character per eye, joined by a space.
    public static func eyePairs(for mood: Mood) -> [String] {
        switch mood {
        case .idle: ["• •", "◕ ◕", "ᵔ ᵔ", "· ·"]
        case .listening: ["◉ ◉", "° °", "⊙ ⊙"]
        case .thinking: ["◔ ◔", "¬ ¬", "◑ ◑", "˘ ˘"]
        case .working: ["> <", "• •", "ò ó"]
        case .happy: ["^ ^", "ᗒ ᗕ", "≧ ≦", "✧ ✧"]
        case .error: ["× ×", "; ;", "ಥ ಥ", "@ @"]
        case .sleepy: ["- -", "_ _", "︶ ︶"]
        case .panicked: ["⊙ ⊙", "◎ ◎", "O O"]
        case .warm: ["≖ ≖", "ᵕ ᵕ", "• •"]
        case .tired: ["◡ ◡", "ᴗ ᴗ", "= ="]
        }
    }

    public static func mouth(for mood: Mood) -> Mouth {
        switch mood {
        case .idle: .smile
        case .listening: .open
        case .thinking: .flat
        case .working: .flat
        case .happy: .grin
        case .error: .frown
        case .sleepy: .flat
        case .panicked: .open
        case .warm: .smile
        case .tired: .flat
        }
    }

    /// A random eye pair for `mood`, never `previous` when the mood has another.
    public static func eyes<R: RandomNumberGenerator>(for mood: Mood, avoiding previous: String?, using random: inout R) -> String {
        let pairs = eyePairs(for: mood)
        let choices = pairs.count > 1 ? pairs.filter { $0 != previous } : pairs
        return choices.randomElement(using: &random) ?? pairs[0]
    }

    public static func eyes(for mood: Mood, avoiding previous: String?) -> String {
        var random = SystemRandomNumberGenerator()
        return eyes(for: mood, avoiding: previous, using: &random)
    }

    /// How the Mac is doing, read while the bean is on screen.
    public struct Vitals: Equatable, Sendable {
        /// All cores together, 0…1.
        public var cpu: Double
        /// `ProcessInfo.thermalState` is serious or critical.
        public var hot: Bool
        /// 0…1, nil without a battery.
        public var battery: Double?
        public var charging: Bool

        public init(cpu: Double, hot: Bool, battery: Double?, charging: Bool) {
            self.cpu = cpu
            self.hot = hot
            self.battery = battery
            self.charging = charging
        }
    }

    /// Full load above this.
    public static let panicLoad = 0.9

    /// What the Mac makes the bean feel, and why (shown on hover), when something stands out:
    /// full load first, then heat, then the battery (sleepy under 10 %, tired under 20 %;
    /// plugging in wakes it). Only used while nothing else is going on.
    public static func mood(for vitals: Vitals) -> (mood: Mood, reason: String)? {
        if vitals.cpu >= panicLoad { return (.panicked, "CPU \(Int((vitals.cpu * 100).rounded())) %") }
        if vitals.hot { return (.warm, "Your Mac is warm") }
        if let battery = vitals.battery, !vitals.charging {
            let percent = "Battery \(Int((battery * 100).rounded())) %"
            if battery < 0.1 { return (.sleepy, percent) }
            if battery < 0.2 { return (.tired, percent) }
        }
        return nil
    }

    /// Idle this long and the bean dozes off.
    public static let sleepAfter: TimeInterval = 5 * 60
}
