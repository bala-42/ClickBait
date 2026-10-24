import Foundation

/// The Home card's bean as a toy (user's ask, 2026-10-24): dragged, flung, drifting in zero
/// gravity, bouncing off the card's edges, drifting home when left alone. Points, y down;
/// `offset` is from its resting place in the middle of the card.
public struct SpaceToy: Equatable, Sendable {
    public var offset = Point(x: 0, y: 0)
    /// Points per second.
    public var velocity = Point(x: 0, y: 0)
    public var held = false
    /// Seconds since it was let go (or last hit an edge hard): after `homeAfter`, it goes home.
    public var loose = 0.0

    /// Its speed halves every this many seconds: a slow coast, as in space.
    public static let halfLife = 0.9
    /// The share of its speed it keeps off an edge.
    public static let bounce = 0.7
    public static let homeAfter = 3.0
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
        if loose > Self.homeAfter {
            // Home: a damped spring back to the middle.
            velocity.x += -offset.x * 9 * dt
            velocity.y += -offset.y * 9 * dt
            let damping = pow(0.5, dt / 0.18)
            velocity = Point(x: velocity.x * damping, y: velocity.y * damping)
        } else {
            let coast = pow(0.5, dt / Self.halfLife)
            velocity = Point(x: velocity.x * coast, y: velocity.y * coast)
        }
        offset.x += velocity.x * dt
        offset.y += velocity.y * dt
        var hit = 0.0
        if abs(offset.x) > limit.x {
            offset.x = offset.x < 0 ? -limit.x : limit.x
            hit = max(hit, abs(velocity.x))
            velocity.x = -velocity.x * Self.bounce
        }
        if abs(offset.y) > limit.y {
            offset.y = offset.y < 0 ? -limit.y : limit.y
            hit = max(hit, abs(velocity.y))
            velocity.y = -velocity.y * Self.bounce
        }
        if hit > 200 { loose = 0 }  // a hard bounce: let it ricochet before going home
        if loose > Self.homeAfter, speed < 2, hypot(offset.x, offset.y) < 0.5 {
            offset = Point(x: 0, y: 0)
            velocity = Point(x: 0, y: 0)
        }
        return hit
    }
}
