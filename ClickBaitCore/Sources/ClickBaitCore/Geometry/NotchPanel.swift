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
        /// Notch-sized and black, invisible over the notch; a small side tab shows when
        /// something is worth a glance (an agent working or done).
        case collapsed
        case expanded
    }

    public enum Event: Equatable, Sendable {
        /// The pointer rested on the notch for `hoverDelay`.
        case hoverDwelled
        /// The pointer left the panel for `leaveDelay`.
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

    /// Long enough that passing over the notch on the way to the menu bar never opens it
    /// (user's choice, 2026-10-14; was 0.25 s).
    public static let hoverDelay = 0.5
    public static let leaveDelay = 0.4

    public static func next(_ state: State, on event: Event) -> State {
        switch (state, event) {
        case (_, .enabled(false)), (_, .displayAvailable(false)): .hidden
        case (.hidden, .enabled(true)), (.hidden, .displayAvailable(true)): .collapsed
        case (.collapsed, .hoverDwelled), (.collapsed, .clicked), (.collapsed, .pulledDown): .expanded
        case (.expanded, .clicked), (.expanded, .escape), (.expanded, .pointerLeft), (.expanded, .pushedUp): .collapsed
        default: state
        }
    }

    // MARK: Layout

    /// The notch: between the menu bar's two usable areas at the top of the screen
    /// (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, macOS 12). Nil without one.
    public static func notch(screen: Rect, topInset: Double, leftArea: Rect?, rightArea: Rect?) -> Rect? {
        guard topInset > 0, let left = leftArea, let right = rightArea, right.minX > left.maxX else { return nil }
        return Rect(x: left.maxX, y: screen.maxY - topInset, width: right.minX - left.maxX, height: topInset)
    }

    /// The side tab's width when collapsed with something to show.
    public static let tabWidth = 30.0
    /// The volume HUD's wings, each side of the notch while it shows (collapsed only).
    public static let hudWing = 96.0
    public static let expandedSize = (width: 680.0, height: 180.0)
    /// Without a notch: a small pill this size, top-centre under the menu bar.
    public static let pillSize = (width: 180.0, height: 26.0)

    /// The panel's frame. Collapsed it covers only the notch (plus the tab on its right when
    /// `showsTab`), so it never covers menu-bar items. Expanded it hangs from the top, centred
    /// on the notch, kept on the screen. Without a notch: a pill under the menu bar.
    public static func frame(_ state: State, screen: Rect, visible: Rect, notch: Rect?, showsTab: Bool,
                             showsHUD: Bool = false) -> Rect? {
        switch state {
        case .hidden:
            return nil
        case .collapsed:
            if let notch, showsHUD {
                return Rect(x: notch.x - hudWing, y: notch.y, width: notch.width + 2 * hudWing, height: notch.height)
            }
            if let notch {
                return Rect(x: notch.x, y: notch.y, width: notch.width + (showsTab ? tabWidth : 0), height: notch.height)
            }
            return Rect(x: screen.midX - pillSize.width / 2, y: visible.maxY - pillSize.height - 4,
                        width: pillSize.width, height: pillSize.height)
        case .expanded:
            let width = min(max(expandedSize.width, (notch?.width ?? 0) + 2 * 60), screen.width - 16)
            let centre = notch?.midX ?? screen.midX
            let x = min(max(centre - width / 2, screen.minX + 8), screen.maxX - 8 - width)
            let top = notch != nil ? screen.maxY : visible.maxY - 4
            return Rect(x: x, y: top - expandedSize.height, width: width, height: expandedSize.height)
        }
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

/// CPU use from two samples of the processor tick counters (`host_statistics`'s user,
/// system, idle and nice ticks): busy share of the ticks between them, 0…1. Pure.
public enum CPUUsage {
    public struct Ticks: Equatable, Sendable {
        public var user, system, idle, nice: UInt64
        public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
            self.user = user
            self.system = system
            self.idle = idle
            self.nice = nice
        }
    }

    public static func busy(from earlier: Ticks, to later: Ticks) -> Double? {
        func delta(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) : 0 }  // a counter that wrapped counts as 0
        let busy = delta(earlier.user, later.user) + delta(earlier.system, later.system) + delta(earlier.nice, later.nice)
        let total = busy + delta(earlier.idle, later.idle)
        return total > 0 ? busy / total : nil
    }
}
