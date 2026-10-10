import Foundation

/// A damped spring for motion that starts gently and settles smoothly, unlike easing a
/// fixed fraction of the way each frame (which leaves at full speed and re-targets
/// abruptly). `Spring(period: r, damping: ζ)` is SwiftUI's `.spring(response: r,
/// dampingFraction: ζ)`.
public struct Spring: Sendable {
    /// Angular frequency: higher is snappier. 2π / period.
    public var omega: Double
    /// 1 settles without overshoot; a little under 1 adds a soft settle.
    public var damping: Double

    public init(period: Double, damping: Double) {
        omega = 2 * .pi / period
        self.damping = damping
    }

    /// Advances `value` (with `velocity`) toward `target` by `dt` seconds, exactly: the
    /// closed-form motion of a damped spring, so any frame length gives the same path and a
    /// dropped frame can't make it unstable. (Stepping in 1/240 s slices was 5% off for the
    /// follow's stiff spring, 2026-10-11.)
    public func step(_ value: inout Double, velocity: inout Double, toward target: Double, dt: Double) {
        let t = max(dt, 0)
        guard t > 0, omega > 0 else { return }
        let a = value - target, v = velocity
        let zeta = max(damping, 0)
        let offset: Double, speed: Double
        if abs(zeta - 1) < 1e-6 {  // critically damped
            let c = v + omega * a
            let decay = exp(-omega * t)
            offset = (a + c * t) * decay
            speed = (c - omega * (a + c * t)) * decay
        } else if zeta < 1 {  // underdamped: overshoots and settles
            let damped = omega * (1 - zeta * zeta).squareRoot()
            let b = (v + zeta * omega * a) / damped
            let decay = exp(-zeta * omega * t)
            let cosine = cos(damped * t), sine = sin(damped * t)
            offset = decay * (a * cosine + b * sine)
            speed = decay * ((b * damped - zeta * omega * a) * cosine - (a * damped + zeta * omega * b) * sine)
        } else {  // overdamped
            let root = (zeta * zeta - 1).squareRoot()
            let r1 = -omega * (zeta - root), r2 = -omega * (zeta + root)
            let c1 = (v - r2 * a) / (r1 - r2), c2 = a - c1
            let e1 = exp(r1 * t), e2 = exp(r2 * t)
            offset = c1 * e1 + c2 * e2
            speed = c1 * r1 * e1 + c2 * r2 * e2
        }
        value = target + offset
        velocity = speed
    }

    /// Close enough and slow enough to stop animating.
    public static func isSettled(_ value: Double, velocity: Double, target: Double, tolerance: Double) -> Bool {
        abs(target - value) < tolerance && abs(velocity) < tolerance * 10
    }
}
