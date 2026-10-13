import Foundation

/// Background ClickBaits as a dock of tiles, after HeyClicky's agents (measured from its demo
/// video at ~2.1 video px a point; closed source, so the look and motion only). Sizes are
/// points; frames are AppKit's (y up). Pure: the app draws it.
public enum AgentDock {
    // MARK: Tiles (video 104 s and 140 s)
    public static let tileSize = 33.0
    public static let tileCorner = 10.0
    /// Top to top: 33 pt tiles with a 9 pt gap.
    public static let pitch = 42.0
    /// The tiles' right edge from the screen's right edge, and the first tile below the menu bar.
    public static let rightInset = 27.0
    public static let topInset = 32.0
    public static let triangleSize = 14.0
    public static let dotDiameter = 6.0
    /// The status dot's centre, in from the tile's top and right edges.
    public static let dotInset = 4.5

    // MARK: Cards (video 31 s, 152 s, 204–208 s)
    /// Measured 608 video px ≈ 290 pt; 288 keeps whole points.
    public static let cardWidth = 288.0
    public static let cardCorner = 12.0
    public static let cardGap = 8.0
    public static let cardSidePadding = 14.0
    public static let cardTopPadding = 15.0

    // MARK: Spawn (video 102.5–103.2 s, stepped at 1/30 s)
    /// The companion turns the job's colour and grows at the cursor first (to ~2.2× in the
    /// video, 102.50–102.60 s).
    public static let growTime = 0.1
    public static let grownScale = 2.0
    /// Leaving the cursor (102.63 s) to docking (103.17–103.2 s): ~0.55 s.
    public static let flightTime = 0.55
    /// The fresh companion appears this long after the flight sets off, and pops in over `popTime`.
    public static let freshDelay = 0.0
    /// The new tile is in its slot (and the older ones a slot down) early in the flight, so
    /// the triangle flies into it (102.77 s: the tile is there, the triangle midway).
    public static let tileShare = 0.3
    /// The companion rests at −35°; a tile's triangle points straight up.
    public static let restingAngle = -35.0
    public static let popTime = 0.2

    public static let maxTiles = CapsuleLayout.maxCapsules

    /// Slot `index` (0 = the top, the newest job), in `visible` (the menu-bar screen's
    /// visible frame: below the menu bar, y up). Nil past the last slot.
    public static func tile(_ index: Int, in visible: Rect) -> Rect? {
        guard (0..<maxTiles).contains(index) else { return nil }
        return Rect(x: visible.maxX - rightInset - tileSize,
                    y: visible.maxY - topInset - tileSize - Double(index) * pitch,
                    width: tileSize, height: tileSize)
    }

    /// The status dot's centre for a tile (y up).
    public static func dotCenter(of tile: Rect) -> Point {
        Point(x: tile.maxX - dotInset, y: tile.maxY - dotInset)
    }

    /// A card hanging `cardGap` below `tile`, right edges aligned, kept inside `visible`.
    public static func card(under tile: Rect, height: Double, in visible: Rect) -> Rect {
        let width = min(cardWidth, visible.width - 16)
        let x = max(visible.minX + 8, tile.maxX - width)
        let top = tile.minY - cardGap
        let y = max(visible.minY + 8, top - height)
        return Rect(x: x, y: y, width: width, height: min(height, top - y))
    }

    /// Newest first: a new job takes the top slot and the others move down one.
    public static func slots<ID: Hashable>(newestFirst ids: [ID]) -> [ID: Int] {
        Dictionary(uniqueKeysWithValues: ids.prefix(maxTiles).enumerated().map { ($1, $0) })
    }

    // MARK: The spawn

    public struct SpawnFrame: Equatable, Sendable {
        /// The flying triangle's centre, scale (1 = the companion's 16 pt) and angle (degrees).
        public var center: Point
        public var scale: Double
        public var angle: Double
        /// The tile forming around it (0…1), and the flight's swell for the glow (0…0.3).
        public var tileOpacity: Double
        public var swell: Double
        /// The fresh companion at the cursor: 0 (not yet) … 1 (popped in).
        public var freshScale: Double
        public var docked: Bool
    }

    /// The peel at `elapsed` seconds: grow at the cursor, then a fast arc (`FlightArc`'s
    /// curve, swell and easing, at `flightTime`) into the slot. The tile fades in over the
    /// first `tileShare` of the flight; the triangle stays big until halfway, then shrinks to
    /// `triangleSize` and turns upright as it lands.
    public static func spawn(at elapsed: Double, from cursor: Point, to slot: Point) -> SpawnFrame {
        let companion = 16.0, landed = triangleSize / companion
        if elapsed < growTime {
            let grow = FlightArc.smoothstep(elapsed / growTime)
            return SpawnFrame(center: cursor, scale: 1 + (grownScale - 1) * grow, angle: restingAngle,
                              tileOpacity: 0, swell: 0,
                              freshScale: 0, docked: false)
        }
        let arc = FlightArc(from: cursor, to: slot)
        let flown = elapsed - growTime
        let progress = min(max(flown / flightTime, 0), 1)
        let eased = FlightArc.smoothstep(progress)
        let fresh = min(max((flown - freshDelay) / popTime, 0), 1)
        let tile = FlightArc.smoothstep(progress / tileShare)
        let landing = FlightArc.smoothstep((progress - 0.5) / 0.5)
        let scale = grownScale + (landed - grownScale) * landing
        return SpawnFrame(center: arc.point(at: eased), scale: scale * (1 + arc.swell * sin(.pi * progress)),
                          angle: restingAngle * (1 - landing),
                          tileOpacity: tile, swell: arc.swell * sin(.pi * progress),
                          freshScale: FlightArc.smoothstep(fresh), docked: progress >= 1)
    }

    /// How far the older tiles have slid down their one slot (0…1) at `elapsed`: they make
    /// room while the new one flies, done as it lands.
    public static func slide(at elapsed: Double) -> Double {
        FlightArc.smoothstep((elapsed - growTime) / (flightTime * tileShare))
    }

    // MARK: How a tile looks

    public enum Status: Sendable { case working, done, failed, stopped }

    public enum Dot: String, Sendable { case azure, shamrock, grey }

    public struct Look: Equatable, Sendable {
        public var dot: Dot
        public var spins: Bool
        public var pulses: Bool
        public var dimmed: Bool
    }

    /// Working spins (a pulse with Reduce Motion), done pulses until opened, failed or
    /// stopped is dimmed. The dot: Azure working, Shamrock done, grey otherwise.
    public static func look(_ status: Status, opened: Bool, reduceMotion: Bool) -> Look {
        switch status {
        case .working: Look(dot: .azure, spins: !reduceMotion, pulses: reduceMotion, dimmed: false)
        case .done: Look(dot: .shamrock, spins: false, pulses: !opened, dimmed: false)
        case .failed, .stopped: Look(dot: .grey, spins: false, pulses: false, dimmed: true)
        }
    }
}
