/// Modifier keys, independent of AppKit so the hotkey logic can be shared and tested.
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let command = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)
}

/// Turns modifier changes and key presses into ClickBait's two hotkeys:
///
/// - **Ask** — hold ⌃⌥ (Control+Option) alone, talk, let go.
/// - **Explain / snip** — ⌥⌘ (Option+Command) alone. A tap explains the highlighted
///   text; holding it while tracing or dragging snips part of the screen. Which one it
///   was is decided by the app from what happened between press and release.
///
/// Pressing any other key, or adding another modifier, means the user is reaching for a
/// real shortcut (⌃⌥←, ⌥⌘Esc, ⌥⌘D…): either chord is cancelled.
public struct ChordDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case askPressed
        case askReleased
        case askCancelled
        case explainPressed
        case explainReleased
        case explainCancelled
    }

    public static let ask: Modifiers = [.control, .option]
    public static let explain: Modifiers = [.option, .command]

    private var askHeld = false
    private var explainArmed = false

    public init() {}

    public mutating func modifiersChanged(to modifiers: Modifiers) -> [Event] {
        var events: [Event] = []

        if modifiers == Self.ask {
            if !askHeld {
                askHeld = true
                events.append(.askPressed)
            }
        } else if askHeld {
            askHeld = false
            events.append(modifiers.isStrictSuperset(of: Self.ask) ? .askCancelled : .askReleased)
        }

        if modifiers == Self.explain {
            if !explainArmed {
                explainArmed = true
                events.append(.explainPressed)
            }
        } else if explainArmed {
            explainArmed = false
            // Letting go of either key fires; adding a modifier doesn't.
            events.append(modifiers.isStrictSubset(of: Self.explain) ? .explainReleased : .explainCancelled)
        }
        return events
    }

    public mutating func keyPressed() -> [Event] {
        var events: [Event] = []
        if explainArmed {
            explainArmed = false
            events.append(.explainCancelled)
        }
        if askHeld {
            askHeld = false
            events.append(.askCancelled)
        }
        return events
    }
}
