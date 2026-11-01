import Foundation

/// ClickBait's notch panel (user's request, 2026-10-14): a small panel at the MacBook notch
/// that grows into a few widgets — agent status, mode toggles, music, a quick note, clock and
/// stats. Clean-room: boring.notch (GPL-3.0) was a reference for the idea only; none of its
/// code or assets were read or used. Pure: states, transitions and layout; the app draws it.
/// Frames are AppKit's (y up).
public enum NotchPanel {
    public enum State: Equatable, Sendable {
        /// Turned off, or no display to show it on.
        case hidden
        /// Notch-sized and black, invisible over the notch; the music wings show while playing.
        case collapsed
        /// The pointer came by: a small island `peekWidth` wider than the notch, the bean on
        /// its left, sliding out on the way to open (`openDwell`).
        case peek
        case expanded
    }

    public enum Event: Equatable, Sendable {
        /// The pointer came onto the notch.
        case pointerEntered
        /// The pointer stayed on the peek for `openDwell`.
        case pointerStayed
        /// The pointer stayed away from the panel for `leaveHold`.
        case pointerLeft
        case clicked
        case escape
        /// A two-finger swipe down on the notch (`PullGesture`), or up on the open panel.
        case pulledDown
        case pushedUp
        case enabled(Bool)
        /// The panel's display came or went (lid closed, notch display unplugged).
        case displayAvailable(Bool)
    }

    /// The island's rhythm (user's rule, 2026-10-21): the pointer on the notch slides it out —
    /// the peek at once, open after `openDwell` (a click opens at once); the pointer away for
    /// `leaveHold` folds it right back into the notch, as do Esc and ✕.
    public static let openDwell = 0.2
    public static let leaveHold = 0.4
    /// The peek: this much wider than the notch.
    public static let peekWidth = 160.0

    /// Whether the pointer counts as on the panel, with hysteresis (adapted from Sentient OS,
    /// AGPL-3.0): coming on needs the pointer on the black itself, so brushing past doesn't slide
    /// it out; leaving needs it `exitMargin` outside, so a pointer resting on the edge doesn't
    /// flicker it. Both reach `topOverhang` above the frame: a pointer pushed against the top of
    /// the screen reports y = the screen's top, which a half-open rect test would miss.
    public static let exitMargin = 4.0
    public static let topOverhang = 2.0

    public static func pointerOn(_ point: Point, frame: Rect, wasOn: Bool) -> Bool {
        let margin = wasOn ? exitMargin : 0
        return point.x >= frame.minX - margin && point.x <= frame.maxX + margin
            && point.y >= frame.minY - margin && point.y <= frame.maxY + topOverhang
    }

    public static func next(_ state: State, on event: Event) -> State {
        switch (state, event) {
        case (_, .enabled(false)), (_, .displayAvailable(false)): .hidden
        case (.hidden, .enabled(true)), (.hidden, .displayAvailable(true)): .collapsed
        case (.collapsed, .pointerEntered): .peek
        case (.collapsed, .clicked), (.collapsed, .pulledDown), (.peek, .clicked), (.peek, .pulledDown), (.peek, .pointerStayed): .expanded
        case (.expanded, .escape), (.expanded, .pushedUp), (.expanded, .pointerLeft),
             (.peek, .escape), (.peek, .pushedUp), (.peek, .pointerLeft): .collapsed
        default: state
        }
    }

    /// The notch: between the menu bar's two usable areas at the top of the screen
    /// (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, macOS 12). Nil without one.
    public static func notch(screen: Rect, topInset: Double, leftArea: Rect?, rightArea: Rect?) -> Rect? {
        guard topInset > 0, let left = leftArea, let right = rightArea, right.minX > left.maxX else { return nil }
        return Rect(x: left.maxX, y: screen.maxY - topInset, width: right.minX - left.maxX, height: topInset)
    }

    // MARK: Layout — measured from the user's GIF (the design's source of truth, 2026-10-14):
    // 601 frames; its notch is 248 px = 185 pt, so 1 GIF px = 0.746 pt.

    /// The music "live activity": the black grows this much each side of the notch, with the
    /// artwork on the left wing and a visualizer on the right (GIF: 248 → 356 px).
    public static let activityWing = 40.0
    /// The volume HUD's wings, each side of the notch while it shows: the speaker left, the
    /// percentage right, room for "100%" in the arcade font.
    public static let hudWing = 112.0
    /// Under the notch, the HUD's Pac-Man corridor: the level as a row of dots, as long as the
    /// HUD is wide (user's choice, 2026-10-23).
    public static let hudCorridor = 24.0
    /// Without a notch, the HUD's middle between its wings (where the notch would be).
    public static let hudGap = 120.0
    /// The open island (user's choice, 2026-10-20; ClickBait's colours): 640 wide, 160 tall — 8 top, a 34 pt header, 98 pt of
    /// cards, 10 bottom.
    public static let expandedSize = (width: 640.0, height: 160.0)
    /// The shelf (files, AirDrop, note) gets taller cards for its file drop.
    public static let shelfSize = (width: 640.0, height: 176.0)
    /// The Mirror photo booth: a 420 × 236 camera beside its shutter and the last four shots.
    /// Studio: its header, the Mirror / Prompter switch on a row below the notch, the content.
    public static let mirrorSize = (width: 640.0, height: 326.0)
    /// The Ask tab once a conversation starts in it: room for the answer and its code.
    public static let chatSize = (width: 640.0, height: 400.0)
    /// Corners: 22 open, 14 for the small island (wings, peek, HUD).
    public static let openCorner = 22.0
    public static let compactCorner = 14.0
    /// Settings remain attached to the notch while opening a roomier in-panel layout.
    public static let settingsSize = (width: 900.0, height: 620.0)
    /// The top corners flare out into the menu bar this much: none, flush with the top.
    public static let ear = 0.0
    /// Without a notch: a small pill this size, top-centre under the menu bar.
    public static let pillSize = (width: 180.0, height: 26.0)

    /// Motion: opening and tab changes spring with a little bounce; closing eases
    /// out quickly (a timing curve, 0.34 s), with no bounce.
    public static let openSpring = (response: 0.5, damping: 0.72)
    public static let closeCurve = (x1: 0.45, y1: 0.0, x2: 0.2, y2: 1.0, duration: 0.34)

    /// The black shape for a state: its size and bottom corner radius (not counting the ears).
    /// `prompter`: Studio's prompter, prompting in the notch — the open notch *is* the prompter,
    /// at its size (user's ask, 2026-11-01: "the thing does not turn into the prompter").
    public static func shape(_ state: State, notch: Rect?, activity: Bool, hud: Bool,
                             shelf: Bool = false, settings: Bool = false, mirror: Bool = false, chat: Bool = false,
                             prompter: (width: Double, height: Double)? = nil)
        -> (width: Double, height: Double, radius: Double) {
        let expanded = prompter ?? (settings ? settingsSize : mirror ? mirrorSize : chat ? chatSize : shelf ? shelfSize : expandedSize)
        guard let notch else {
            // The volume HUD keeps its full size without a notch (a second display): its wings
            // either side of an empty middle, and the corridor under them.
            if hud, state == .collapsed || state == .peek {
                return (2 * hudWing + hudGap, pillSize.height + hudCorridor, compactCorner)
            }
            return state == .expanded
                ? (expanded.width, expanded.height, openCorner)
                : (pillSize.width, pillSize.height, pillSize.height / 2)
        }
        switch state {
        case .hidden:
            return (0, 0, 0)
        case .expanded:
            if prompter != nil { return (max(expanded.width, notch.width + 24), expanded.height, openCorner) }
            return (max(expanded.width, notch.width + 2 * activityWing), expanded.height, openCorner)
        case .peek:
            if hud { return (notch.width + 2 * hudWing, notch.height + hudCorridor, compactCorner) }
            return (notch.width + peekWidth, notch.height, compactCorner)
        case .collapsed:
            if hud { return (notch.width + 2 * hudWing, notch.height + hudCorridor, compactCorner) }
            if activity { return (notch.width + 2 * activityWing, notch.height, compactCorner) }
            return (notch.width, notch.height, 8)
        }
    }

    /// The window: the shape plus its ears, centred on the notch and flush with the top (no
    /// notch: under the menu bar), kept on the screen. Collapsed it covers only what the black
    /// covers, so menu-bar items either side stay clickable.
    public static func frame(_ state: State, screen: Rect, visible: Rect, notch: Rect?, activity: Bool = false,
                             hud: Bool = false, shelf: Bool = false,
                             settings: Bool = false, mirror: Bool = false, chat: Bool = false,
                             prompter: (width: Double, height: Double)? = nil) -> Rect? {
        guard state != .hidden else { return nil }
        let look = shape(state, notch: notch, activity: activity, hud: hud,
                         shelf: shelf, settings: settings, mirror: mirror, chat: chat, prompter: prompter)
        let width = min(look.width + 2 * ear, screen.width - 16)
        let centre = notch?.midX ?? screen.midX
        let x = min(max(centre - width / 2, screen.minX + 8), screen.maxX - 8 - width)
        let top = notch != nil ? screen.maxY : visible.maxY - 4
        return Rect(x: x, y: top - look.height, width: width, height: look.height)
    }

    /// What the AirDrop pad sends: the files dropped on it; else the shelf's selection, in
    /// shelf order; else every file on the shelf. Files only, each once.
    public static func airDropItems(dropped: [URL] = [], shelf: [URL], selected: Set<URL>) -> [URL] {
        var seen = Set<URL>()
        let chosen = !dropped.isEmpty ? dropped : selected.isEmpty ? shelf : shelf.filter(selected.contains)
        return chosen.filter { $0.isFileURL && seen.insert($0).inserted }
    }
}

/// Pull down to open, push up to close: two-finger scrolls over the notch, added up within one
/// gesture, by which way the fingers move — the same with natural scrolling on or off. Pure.
public struct PullGesture: Sendable {
    /// Points of finger travel before it counts.
    public static let threshold = 24.0

    private var travel = 0.0
    private var fired = false

    public init() {}

    /// One scroll event: `deltaY` as AppKit reports it, `inverted` = natural scrolling
    /// (`isDirectionInvertedFromDevice`), `ended` = the gesture's last event. Fires once a gesture.
    public mutating func add(deltaY: Double, inverted: Bool, ended: Bool = false) -> NotchPanel.Event? {
        defer { if ended { travel = 0; fired = false } }
        guard !fired else { return nil }
        // Fingers moving down: content follows them with natural scrolling (+), else the reverse.
        travel += inverted ? deltaY : -deltaY
        if travel >= Self.threshold { fired = true; return .pulledDown }
        if travel <= -Self.threshold { fired = true; return .pushedUp }
        return nil
    }
}

/// The volume keys, as the notch HUD handles them: 16 steps, or quarter steps with Option and
/// Shift held (as macOS does); mute toggles; the level shows 0 while muted. Pure.
public enum VolumeStep {
    public enum Key: Equatable, Sendable { case up, down, mute }

    public static let step = 1.0 / 16
    public static let fineStep = step / 4

    /// The new (volume, muted) after a key press.
    public static func apply(_ key: Key, volume: Double, muted: Bool, fine: Bool = false) -> (volume: Double, muted: Bool) {
        let size = fine ? fineStep : step
        switch key {
        case .mute: return (volume, !muted)
        case .up: return ((min(1, volume + size) * 1000).rounded() / 1000, false)  // up unmutes, as macOS does
        case .down:
            let lowered = max(0, ((volume - size) * 1000).rounded() / 1000)
            return (lowered, lowered == 0 ? true : muted)
        }
    }

    /// The `NX_SYSDEFINED` key codes (`NX_KEYTYPE_SOUND_UP` 0, `…_DOWN` 1, `…_MUTE` 7).
    public static func key(forSystemCode code: Int) -> Key? {
        switch code {
        case 0: .up
        case 1: .down
        case 7: .mute
        default: nil
        }
    }
}


/// The brightness keys, as the notch's sky HUD takes them: macOS's 16 steps (a quarter step
/// with ⌥⇧), as the volume's.
public enum BrightnessStep {
    /// The `NX_SYSDEFINED` key codes (`NX_KEYTYPE_BRIGHTNESS_UP` 2, `…_DOWN` 3).
    public static func key(forSystemCode code: Int) -> VolumeStep.Key? {
        switch code {
        case 2: .up
        case 3: .down
        default: nil
        }
    }

    public static func apply(_ key: VolumeStep.Key, level: Double, fine: Bool = false) -> Double {
        let size = fine ? VolumeStep.fineStep : VolumeStep.step
        let next = key == .up ? level + size : key == .down ? level - size : level
        return (min(1, max(0, next)) * 1000).rounded() / 1000
    }
}

/// A track's times as the GIF shows them ("2:57", "3:54", "1:02:05" past an hour), and the
/// position a drag along the progress bar asks for. Pure.
public enum TrackTime {
    public static func text(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// Where along the bar (0…1) a point x is, kept on it.
    public static func position(x: Double, width: Double, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(x / width, 0), 1) * duration
    }

    /// Where playback is now: the last reading, plus the time since while playing.
    public static func now(reported: Double, at reading: Date, playing: Bool, duration: Double, now: Date = .now) -> Double {
        let elapsed = playing ? now.timeIntervalSince(reading) : 0
        return min(max(reported + elapsed, 0), max(duration, 0))
    }
}
