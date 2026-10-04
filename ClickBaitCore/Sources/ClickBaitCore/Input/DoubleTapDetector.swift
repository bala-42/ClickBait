/// Tells a single ⌥⌘ tap (explain the highlighted text) from a double tap (open a chat
/// to type into, no mouse or selection needed).
///
/// A tap can only be called "single" once the window for a second one has passed, so
/// the app waits `window` before acting on `.first`, and drops that pending action if
/// `.second` arrives. Times are seconds on any monotonic clock.
public struct DoubleTapDetector: Sendable {
    public enum Tap: Equatable, Sendable {
        /// May still become a double tap: act on it after `window` if nothing follows.
        case first
        /// The second tap within `window` of the first.
        case second
    }

    /// Long enough for a comfortable double tap, short enough that a single tap's
    /// explanation doesn't feel held back.
    public static let defaultWindow: Double = 0.3

    public let window: Double
    private var firstTapAt: Double?

    public init(window: Double = Self.defaultWindow) {
        self.window = window
    }

    public mutating func tap(at time: Double) -> Tap {
        if let first = firstTapAt, time - first <= window {
            firstTapAt = nil  // a third tap starts over
            return .second
        }
        firstTapAt = time
        return .first
    }

    /// Something other than a tap happened (a snip, another shortcut): the next tap is a
    /// first tap again.
    public mutating func reset() {
        firstTapAt = nil
    }
}
