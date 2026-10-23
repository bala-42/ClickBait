import Foundation

/// The notch's character (user's choice, 2026-10-21; pill eyes 2026-10-22): a soft pearl bean
/// with no mouth, only drawn eyes (tall rounded pills, dashes, chevrons and dots), wearing
/// ClickBait's state colours as a glow. A soft, wide squircle. Each mood has a few eye pairs;
/// a new one is picked whenever the mood changes, avoiding the last one shown.
///
///     let eyes = Bean.eyes(for: .thinking, avoiding: nil)  // e.g. two pills leaning up-left
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
        /// A command finished.
        case happy
        /// Saying hello when the island opens at launch: happy, but pearl.
        case hello
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

    /// One eye. Tilts are in degrees, positive leaning the top to the right.
    public enum Eye: Sendable, Hashable {
        /// A tall rounded pill; `height` is a share of the full height.
        case pill(height: Double = 1, tilt: Double = 0)
        /// A short flat dash: closed, squinting or winking.
        case dash(tilt: Double = 0)
        /// An upturned "^": pleased.
        case chevron
        /// A round dot: wide awake or startled.
        case dot
    }

    public struct EyePair: Sendable, Hashable {
        public let left: Eye
        public let right: Eye

        public init(_ left: Eye, _ right: Eye) {
            self.left = left
            self.right = right
        }

        /// The same eye twice.
        public static func both(_ eye: Eye) -> EyePair { EyePair(eye, eye) }
    }

    /// The eye pairs for each mood.
    public static func eyePairs(for mood: Mood) -> [EyePair] {
        switch mood {
        case .idle: [.both(.pill()), .both(.pill(tilt: 8)), .both(.pill(tilt: -8))]
        case .listening: [.both(.pill(height: 1.2)), .both(.pill(height: 1.2, tilt: 6))]
        case .thinking: [.both(.pill(height: 0.85, tilt: -16)), .both(.pill(height: 0.85, tilt: 16)), .init(.pill(), .dash())]
        case .working: [.both(.pill(height: 0.7, tilt: 20)), .both(.pill(height: 0.7, tilt: -20))]
        case .happy: [.both(.chevron), .init(.chevron, .pill(tilt: 10))]
        case .hello: [.both(.chevron), .init(.pill(), .dash())]
        case .error: [.init(.pill(tilt: -22), .pill(tilt: 22)), .init(.pill(tilt: -22), .dash())]
        case .sleepy: [.both(.dash()), .init(.dash(tilt: 8), .dash(tilt: -8))]
        case .panicked: [.both(.dot), .init(.dot, .pill(height: 1.2))]
        case .warm: [.both(.dash()), .both(.pill(height: 0.6))]
        case .tired: [.both(.pill(height: 0.55)), .init(.dash(), .pill(height: 0.55))]
        }
    }

    /// A random eye pair for `mood`, never `previous` when the mood has another.
    public static func eyes<R: RandomNumberGenerator>(for mood: Mood, avoiding previous: EyePair?, using random: inout R) -> EyePair {
        let pairs = eyePairs(for: mood)
        let choices = pairs.count > 1 ? pairs.filter { $0 != previous } : pairs
        return choices.randomElement(using: &random) ?? pairs[0]
    }

    public static func eyes(for mood: Mood, avoiding previous: EyePair?) -> EyePair {
        var random = SystemRandomNumberGenerator()
        return eyes(for: mood, avoiding: previous, using: &random)
    }

    /// The dock's beans each wear their own face, so jobs side by side never look alike
    /// (user's choice, 2026-10-23). Friendly ones only: no error, sleepy or panicked looks.
    public static let dockFaces: [EyePair] = [
        .both(.pill()), .both(.chevron), .init(.pill(), .dash()), .both(.dot), .both(.pill(tilt: 10)),
        .init(.chevron, .pill(tilt: 10)), .both(.pill(height: 1.2)), .init(.dot, .pill(height: 1.2)),
    ]

    /// A dock face no tile is wearing now (any, once all are taken).
    public static func dockFace<R: RandomNumberGenerator>(avoiding worn: [EyePair], using random: inout R) -> EyePair {
        let free = dockFaces.filter { !worn.contains($0) }
        return (free.isEmpty ? dockFaces : free).randomElement(using: &random) ?? dockFaces[0]
    }

    public static func dockFace(avoiding worn: [EyePair]) -> EyePair {
        var random = SystemRandomNumberGenerator()
        return dockFace(avoiding: worn, using: &random)
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
