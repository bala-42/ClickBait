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
        /// Nothing has happened for a while.
        case sleepy
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

    /// Idle this long and the bean dozes off.
    public static let sleepAfter: TimeInterval = 5 * 60
}
