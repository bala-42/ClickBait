import SwiftUI

/// The home card while nothing plays (user's choice, 2026-10-23): deep space behind the bean,
/// stars drifting out from it, then now and then a hyperspace warp that stretches them into
/// streaks. Every frame is a function of the clock; Reduce Motion holds the stars still.
struct SpaceScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bean being flung: the stars streak away from where it heads (a little hyperspace).
    @State private var play = SpaceToyPlay.shared

    /// A star: its direction from the centre, speed, where in its flight it starts, size.
    private struct Star {
        let angle: Double
        let speed: Double
        let phase: Double
        let size: Double
    }

    /// The same sky every time: a small fixed generator, not `random()`.
    private static let stars: [Star] = {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<90).map { _ in Star(angle: next() * 2 * .pi, speed: 0.6 + next() * 0.8, phase: next(), size: 0.6 + next() * 1.2) }
    }()

    /// Seconds per drift-and-warp cycle.
    private static let cycle = 9.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let velocity = reduceMotion ? .zero : CGVector(dx: play.toy.velocity.x, dy: play.toy.velocity.y)
            Canvas { context, size in
                draw(in: &context, size: size, time: time, fling: velocity)
            }
        }
        .background(RadialGradient(colors: [Color(hex: 0x141B3A), Color(hex: 0x080A16), Color(hex: 0x040509)],
                                   center: .center, startRadius: 0, endRadius: 200))
        .accessibilityHidden(true)
    }

    /// How hard it warps now, 0 (drifting) to 1 (full hyperspace): a short burst each cycle.
    static func warp(at time: Double) -> Double {
        let t = (time / cycle).truncatingRemainder(dividingBy: 1)
        let burst = max(0, sin((t - 0.6) / 0.4 * .pi))  // the last 40 % of the cycle
        return t < 0.6 ? 0 : burst * burst
    }

    /// How far a star has travelled: the drift plus the warp's extra speed, integrated
    /// exactly (∫ sin²(πu) du = u/2 − sin(2πu)/4π) so no star jumps when the speed changes.
    static func distance(at time: Double) -> Double {
        let cycles = (time / cycle).rounded(.down)
        let t = (time - cycles * cycle) / cycle
        let span = 0.4 * cycle  // the burst's length in seconds
        let u = max(0, (t - 0.6) / 0.4)
        let within = span * (u / 2 - sin(2 * .pi * u) / (4 * .pi))
        return 0.05 * time + 0.9 * (cycles * span / 2 + within)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double, fling: CGVector) {
        // A fling warps the stars as hard as it's fast, flying from a point ahead of it.
        let speed = hypot(fling.dx, fling.dy)
        let lead = min(30, speed * 0.03) / max(1, speed)
        let centre = CGPoint(x: size.width / 2 + fling.dx * lead, y: size.height / 2 + fling.dy * lead)
        let reach = hypot(size.width, size.height) / 2
        let warp = max(Self.warp(at: time), min(1, speed / 900))
        let travelled = Self.distance(at: time)
        for star in Self.stars {
            // 0 at the centre, 1 at the edge; squared so stars speed up as they come closer.
            let progress = (star.phase + travelled * star.speed).truncatingRemainder(dividingBy: 1)
            let radius = progress * progress * reach
            let direction = CGPoint(x: cos(star.angle), y: sin(star.angle))
            let head = CGPoint(x: centre.x + direction.x * radius, y: centre.y + direction.y * radius)
            let fade = min(1, progress * 3)  // born dim near the centre
            let tail = radius * (0.02 + 0.45 * warp)
            let colour = Color(hex: warp > 0.3 ? UInt32(0xCFE3FF) : 0xFFFFFF).opacity(0.35 + 0.65 * fade)
            if tail > star.size * 1.5 {
                var streak = Path()
                streak.move(to: CGPoint(x: head.x - direction.x * tail, y: head.y - direction.y * tail))
                streak.addLine(to: head)
                context.stroke(streak, with: .color(colour), style: StrokeStyle(lineWidth: star.size, lineCap: .round))
            } else {
                context.fill(Path(ellipseIn: CGRect(x: head.x - star.size / 2, y: head.y - star.size / 2,
                                                    width: star.size, height: star.size)), with: .color(colour))
            }
        }
        // A soft glow behind the bean, brighter mid-warp.
        let glow = 46 + 20 * warp
        context.fill(Path(ellipseIn: CGRect(x: centre.x - glow, y: centre.y - glow, width: glow * 2, height: glow * 2)),
                     with: .radialGradient(Gradient(colors: [Color(hex: 0x7FA8FF).opacity(0.18 + 0.2 * warp), .clear]),
                                           center: centre, startRadius: 0, endRadius: glow))
    }
}
