import Foundation

/// Where the companion rests by the cursor (AppKit points, y up): its triangle `offset` right
/// of and below the hotspot; at a screen edge it moves to the mirror spot, the same distance
/// left of or above the hotspot, and stays on the screen (user's reports, 2026-10-14: "iffy
/// at the edge", then "flip once and stay put, but not so far and snappy").
/// - Once: flipping has hysteresis. It flips when the companion would cross the edge, and
///   back only with `margin` to spare, so a cursor resting near the line doesn't flip it on
///   every pixel.
/// - Not far: the mirror spot (35 pt the other way), not the whole box moved past the cursor.
/// - Not snappy: the app eases the side change (`blend`, 0 = right/below, 1 = left/above)
///   over `flipTime` instead of jumping in one frame. Pure.
public enum CompanionPlacement {
    /// Room past the threshold before flipping back.
    public static let margin = 24.0
    /// How long a flip glides.
    public static let flipTime = 0.28

    public struct Side: Equatable, Sendable {
        public var left: Bool
        public var above: Bool
        public init(left: Bool = false, above: Bool = false) {
            self.left = left
            self.above = above
        }
    }

    /// The side the companion should be on for `mouse`, given the side it's on now.
    /// `offset`: the triangle's centre from the hotspot; `inContent`: the triangle's centre
    /// from the companion's top-left.
    public static func side(mouse: Point, content: (width: Double, height: Double), bounds: Rect?,
                            offset: (width: Double, height: Double), inContent: Double, current: Side) -> Side {
        guard let bounds else { return Side() }
        var side = current
        let rightEdge = mouse.x + offset.width - inContent + content.width
        if !side.left, rightEdge > bounds.maxX { side.left = true }
        if side.left, rightEdge + margin <= bounds.maxX { side.left = false }
        let bottomEdge = mouse.y - offset.height + inContent - content.height
        if !side.above, bottomEdge < bounds.minY { side.above = true }
        if side.above, bottomEdge - margin >= bounds.minY { side.above = false }
        return side
    }

    /// The companion's top-left for `mouse`, `blend` of the way from right/below (0) to the
    /// mirror spot left/above (1), kept on the screen.
    public static func topLeft(mouse: Point, content: (width: Double, height: Double), bounds: Rect?,
                               offset: (width: Double, height: Double), inContent: Double,
                               blend: (x: Double, y: Double)) -> Point {
        // Triangle centre on each side, then the corner it puts the content at.
        let rightX = mouse.x + offset.width - inContent, leftX = mouse.x - offset.width - inContent
        let belowY = mouse.y - offset.height + inContent, aboveY = mouse.y + offset.height + inContent
        var x = rightX + (leftX - rightX) * eased(blend.x)
        var y = belowY + (aboveY - belowY) * eased(blend.y)
        if let bounds {
            x = max(bounds.minX, min(x, bounds.maxX - content.width))
            y = min(bounds.maxY, max(y, bounds.minY + content.height))
        }
        return Point(x: x, y: y)
    }

    /// One frame of the glide toward `side` (Reduce Motion: there at once).
    public static func step(_ blend: Double, toward left: Bool, dt: Double, reduceMotion: Bool) -> Double {
        let target = left ? 1.0 : 0.0
        if reduceMotion { return target }
        let move = max(dt, 0) / flipTime
        return blend < target ? min(blend + move, target) : max(blend - move, target)
    }

    static func eased(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
