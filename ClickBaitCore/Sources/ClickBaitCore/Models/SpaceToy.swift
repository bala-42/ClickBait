import Foundation

/// The Home card's bean as a toy (user's ask, 2026-10-24): dragged, and let go it springs back
/// home on an elastic, overshooting and wobbling to rest; a flick throws it first, off the
/// card's edges. Points, y down; `offset` is from its resting place in the middle of the card.
public struct SpaceToy: Equatable, Sendable {
    public var offset = Point(x: 0, y: 0)
    /// Points per second.
    public var velocity = Point(x: 0, y: 0)
    public var held = false
    /// Seconds since it was let go.
    public var loose = 0.0

    /// The elastic home: stiffness (1/s²) and damping (1/s). Underdamped, so it overshoots
    /// and wobbles a few times (about 2 Hz) before resting.
    public static let stiffness = 170.0
    public static let damping = 7.0
    /// The share of its speed it keeps off an edge.
    public static let bounce = 0.7
    /// A flick's top speed, so one wild flick can't tunnel through an edge.
    public static let topSpeed = 1_400.0

    public init() {}

    public var speed: Double { hypot(velocity.x, velocity.y) }
    /// Still moving (or held): the caller keeps stepping it.
    public var isMoving: Bool { held || speed > 2 || hypot(offset.x, offset.y) > 0.5 }

    public mutating func letGo(velocity flick: Point) {
        held = false
        loose = 0
        let scale = min(1, Self.topSpeed / max(1, hypot(flick.x, flick.y)))
        velocity = Point(x: flick.x * scale, y: flick.y * scale)
    }

    /// Moves it on by `dt` seconds within ±`limit`; returns how hard it hit an edge (points per
    /// second, 0 when it didn't).
    public mutating func step(_ dt: Double, limit: Point) -> Double {
        guard !held, dt > 0 else { return 0 }
        loose += dt
        velocity.x += -offset.x * Self.stiffness * dt
        velocity.y += -offset.y * Self.stiffness * dt
        let damping = exp(-Self.damping * dt)
        velocity = Point(x: velocity.x * damping, y: velocity.y * damping)
        offset.x += velocity.x * dt
        offset.y += velocity.y * dt
        // An edge turns it back only while it's heading out: let go beyond an edge (pulled
        // there), the elastic brings it in without a jump.
        var hit = 0.0
        if abs(offset.x) > limit.x, offset.x * velocity.x > 0 {
            hit = max(hit, abs(velocity.x))
            velocity.x = -velocity.x * Self.bounce
        }
        if abs(offset.y) > limit.y, offset.y * velocity.y > 0 {
            hit = max(hit, abs(velocity.y))
            velocity.y = -velocity.y * Self.bounce
        }
        if speed < 2, hypot(offset.x, offset.y) < 0.5 {
            offset = Point(x: 0, y: 0)
            velocity = Point(x: 0, y: 0)
        }
        return hit
    }
}
