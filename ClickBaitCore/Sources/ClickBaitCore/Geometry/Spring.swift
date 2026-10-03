/// A damped spring for motion that starts gently and settles smoothly, unlike easing a
/// fixed fraction of the way each frame (which leaves at full speed and re-targets
/// abruptly). Stepped in small slices so a dropped frame can't make it unstable.
public struct Spring: Sendable {
    /// Angular frequency: higher is snappier. 2π / period.
    public var omega: Double
    /// 1 settles without overshoot; a little under 1 adds a soft settle.
    public var damping: Double

    public init(period: Double, damping: Double) {
        omega = 2 * .pi / period
        self.damping = damping
    }

    static let maxSlice = 1.0 / 240

    /// Advances `value` (with `velocity`) toward `target` by `dt` seconds.
    public func step(_ value: inout Double, velocity: inout Double, toward target: Double, dt: Double) {
        var remaining = max(dt, 0)
        while remaining > 0 {
            let slice = min(remaining, Self.maxSlice)
            let acceleration = omega * omega * (target - value) - 2 * damping * omega * velocity
            velocity += acceleration * slice
            value += velocity * slice
            remaining -= slice
        }
    }

    /// Close enough and slow enough to stop animating.
    public static func isSettled(_ value: Double, velocity: Double, target: Double, tolerance: Double) -> Bool {
        abs(target - value) < tolerance && abs(velocity) < tolerance * 10
    }
}
