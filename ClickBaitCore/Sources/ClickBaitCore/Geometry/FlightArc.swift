import Foundation

/// The companion's flight to a target and home again, after Clicky's (MIT)
/// `animateBezierFlightArc`: a quadratic Bézier whose control point is the midpoint raised
/// by min(distance·0.2, 80) pt, eased with smoothstep, lasting clamp(distance/800, 0.6,
/// 1.4) s, swelling to 1 + 0.3·sin(π·progress) with the glow growing (scale − 1)·20 pt.
///
/// ClickBait's twist for its many short hops (walkthrough steps, tour parts, several
/// targets): below `flatBelow` there's no arc and no swell, so a tour never looks like a
/// bouncing ball; from `fullFrom` it's Clicky's arc; in between both grow linearly.
///
/// Coordinates are AppKit's (y up), so "raised" adds to y. Headings are degrees clockwise
/// from straight up, as the triangle's angle.
public struct FlightArc: Equatable, Sendable {
    public static let flatBelow = 120.0
    public static let fullFrom = 400.0
    public static let maxHeight = 80.0
    public static let heightPerPoint = 0.2
    public static let fullSwell = 0.3
    public static let glowPerSwell = 20.0

    public var start: Point
    public var end: Point
    /// How far the control point is raised above the midpoint.
    public var height: Double
    /// The peak extra scale (0.3 for a full flight, 0 for a short hop).
    public var swell: Double
    public var duration: Double

    public init(from start: Point, to end: Point) {
        self.start = start
        self.end = end
        let distance = Self.distance(start, end)
        let share = Self.arcShare(forDistance: distance)
        height = min(distance * Self.heightPerPoint, Self.maxHeight) * share
        swell = Self.fullSwell * share
        duration = Self.duration(forDistance: distance)
    }

    public var distance: Double { Self.distance(start, end) }

    /// How much of Clicky's arc and swell a flight this long gets: 0 below 120 pt, 1 from 400.
    public static func arcShare(forDistance distance: Double) -> Double {
        min(max((distance - flatBelow) / (fullFrom - flatBelow), 0), 1)
    }

    public static func duration(forDistance distance: Double) -> Double {
        min(max(distance / 800, 0.6), 1.4)
    }

    /// 3t² − 2t³: starts and ends gently.
    public static func smoothstep(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Linear progress (0…1) after `elapsed` seconds.
    public func progress(after elapsed: Double) -> Double {
        duration > 0 ? min(max(elapsed / duration, 0), 1) : 1
    }

    public var control: Point {
        Point(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + height)
    }

    /// Where it is at eased progress `t` (0…1).
    public func point(at t: Double) -> Point {
        let u = 1 - t, c = control
        return Point(x: u * u * start.x + 2 * u * t * c.x + t * t * end.x,
                     y: u * u * start.y + 2 * u * t * c.y + t * t * end.y)
    }

    /// The direction of travel at eased progress `t` (the curve's derivative).
    public func tangent(at t: Double) -> Point {
        let u = 1 - t, c = control
        return Point(x: 2 * u * (c.x - start.x) + 2 * t * (end.x - c.x),
                     y: 2 * u * (c.y - start.y) + 2 * t * (end.y - c.y))
    }

    /// The heading of travel at eased progress `t`, or nil for a flight that goes nowhere.
    public func heading(at t: Double) -> Double? {
        let d = tangent(at: t)
        guard hypot(d.x, d.y) > 1e-6 else { return nil }
        return atan2(d.x, d.y) * 180 / .pi
    }

    /// The swell at linear progress `p`: 1 at both ends, 1 + swell midway.
    public func scale(at p: Double) -> Double {
        1 + swell * sin(.pi * min(max(p, 0), 1))
    }

    /// How much bigger the glow's radius is at linear progress `p` (pt).
    public func glowGrowth(at p: Double) -> Double {
        (scale(at: p) - 1) * Self.glowPerSwell
    }

    static func distance(_ a: Point, _ b: Point) -> Double {
        hypot(b.x - a.x, b.y - a.y)
    }
}
