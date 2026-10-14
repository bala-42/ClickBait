import Foundation

/// The dock folding away so it never covers what's under it (user's request, 2026-10-14):
/// after a short idle, or a click elsewhere, the tiles fade out and only a slim handle stays
/// against the screen's right edge, level with the top slot. A click on the handle, or a
/// quick side-to-side shake of the pointer over it, brings the dock back. Pure: the app
/// (`CapsuleController`) draws and times it. Frames are AppKit's (y up).
public enum DockCollapse {
    /// Folds this long after the pointer was last over the dock, while no card is open.
    public static let idleDelay = 4.0
    public static let fadeOutTime = 0.22
    public static let fadeInTime = 0.18
    /// How far the tiles slide toward the edge as they fade (none with Reduce Motion).
    public static let slide = 10.0

    // MARK: The handle

    public static let handleWidth = 4.0
    public static let handleHeight = 22.0
    /// The handle's right edge in from the screen's right edge.
    public static let handleEdgeInset = 3.0
    /// Clickable room around the handle (its window's margin).
    public static let handleHitMargin = 8.0
    /// The handle at rest is faint; it brightens under the pointer.
    public static let handleRestOpacity = 0.55

    /// The handle, centred on the top slot's height, against the right edge of `visible`.
    public static func handle(in visible: Rect) -> Rect {
        let top = AgentDock.tile(0, in: visible) ?? Rect(x: 0, y: visible.maxY - AgentDock.topInset - AgentDock.tileSize,
                                                         width: AgentDock.tileSize, height: AgentDock.tileSize)
        return Rect(x: visible.maxX - handleEdgeInset - handleWidth, y: top.midY - handleHeight / 2,
                    width: handleWidth, height: handleHeight)
    }

    /// Where a shake counts: the handle and a band to its left, roomy enough for a wiggle.
    public static func shakeZone(in visible: Rect) -> Rect {
        let handle = handle(in: visible)
        let width = 90.0, height = 70.0
        return Rect(x: handle.maxX - width, y: handle.midY - height / 2, width: width + handleEdgeInset, height: height)
    }

    /// The handle's colour says what's waiting: something working (Azure), else a result not
    /// yet opened (Aqua green), else grey.
    public static func handleDot(_ tiles: [(status: AgentDock.Status, opened: Bool)]) -> AgentDock.Dot {
        if tiles.contains(where: { $0.status == .working }) { return .azure }
        if tiles.contains(where: { $0.status == .done && !$0.opened }) { return .aquaGreen }
        return .grey
    }

    /// Whether the open dock folds now: never with a card open or the pointer over it, and
    /// only once it has been left alone for `idleDelay`.
    public static func foldsWhenIdle(cardOpen: Bool, pointerOver: Bool, idleFor: Double) -> Bool {
        !cardOpen && !pointerOver && idleFor >= idleDelay
    }

    /// Whether a click folds the open dock: one outside the dock's windows, with no card open
    /// (that click closes the card first, as before).
    public static func foldsOnClick(cardOpen: Bool, insideDock: Bool) -> Bool {
        !cardOpen && !insideDock
    }
}

/// A quick side-to-side wiggle of the pointer: `reversals` changes of direction, each leg at
/// least `minLeg` points, all within `window` seconds. Vertical drift is ignored. Feed it
/// pointer moves; it says true once per shake, then starts over.
public struct ShakeDetector: Sendable {
    public static let reversals = 3
    public static let minLeg = 12.0
    public static let window = 0.7

    private var anchorX: Double?
    private var direction = 0.0
    /// When each leg began, within `window`: the first leg, then each turn.
    private var turns: [Double] = []

    public init() {}

    public mutating func reset() {
        anchorX = nil
        direction = 0
        turns = []
    }

    /// One pointer position at `time` (seconds). True when it completes a shake.
    public mutating func add(x: Double, at time: Double) -> Bool {
        turns.removeAll { time - $0 > Self.window }
        guard let anchor = anchorX else {
            anchorX = x
            return false
        }
        let moved = x - anchor
        if direction == 0 {
            if abs(moved) >= Self.minLeg {
                direction = moved > 0 ? 1 : -1
                anchorX = x
                turns.append(time)  // the first leg counts toward the window too
            }
            return false
        }
        // Further the same way: the turn is measured from the farthest point.
        if moved * direction >= 0 {
            anchorX = x
            return false
        }
        guard abs(moved) >= Self.minLeg else { return false }
        direction = -direction
        anchorX = x
        turns.append(time)
        guard turns.count > Self.reversals else { return false }
        reset()
        return true
    }
}
