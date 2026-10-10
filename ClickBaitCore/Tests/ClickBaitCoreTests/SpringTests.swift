import Foundation
import Testing
@testable import ClickBaitCore

struct SpringTests {
    private func run(_ spring: Spring, from start: Double, to target: Double, seconds: Double, frame: Double) -> [Double] {
        var value = start, velocity = 0.0
        var trace: [Double] = []
        for _ in 0..<Int(seconds / frame) {
            spring.step(&value, velocity: &velocity, toward: target, dt: frame)
            trace.append(value)
        }
        return trace
    }

    @Test func startsGentlyAndSettles() {
        let trace = run(Spring(period: 0.5, damping: 0.9), from: 0, to: 100, seconds: 1.5, frame: 1.0 / 120)
        #expect(trace[0] < 2)  // no jump on the first frame
        #expect(abs(trace.last! - 100) < 0.5)
        #expect(trace.max()! < 101.5)  // at most a soft overshoot
    }

    @Test func staysStableWhenFramesAreDropped() {
        let trace = run(Spring(period: 0.5, damping: 0.9), from: 0, to: 100, seconds: 2, frame: 0.1)
        #expect(abs(trace.last! - 100) < 0.5)
        #expect(trace.allSatisfy { $0 > -1 && $0 < 102 })
    }

    /// The follow is SwiftUI's `.spring(response: 0.2, dampingFraction: 0.6)` (Clicky's):
    /// stiffness (2π/response)², damping 2ζω — `Spring(period: 0.2, damping: 0.6)`. Checked
    /// against the analytic underdamped step response.
    @Test func matchesSwiftUIsSpring() {
        let response = 0.2, zeta = 0.6
        let omega = 2 * Double.pi / response, damped = omega * (1 - zeta * zeta).squareRoot()
        let frame = 1.0 / 120
        let trace = run(Spring(period: response, damping: zeta), from: 0, to: 1, seconds: 1, frame: frame)
        for (index, value) in trace.enumerated() {
            let t = Double(index + 1) * frame
            let exact = 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta / (1 - zeta * zeta).squareRoot() * sin(damped * t))
            #expect(abs(value - exact) < 1e-9)
        }
        let overshoot = (trace.max() ?? 0) - 1
        #expect(overshoot > 0.08 && overshoot < 0.11)  // exp(−πζ/√(1−ζ²)) ≈ 9.5%
        #expect(abs(trace.last! - 1) < 0.001)
    }

    @Test func frameLengthDoesNotChangeThePath() {
        let fine = run(Spring(period: 0.38, damping: 1), from: 0, to: 100, seconds: 0.5, frame: 1.0 / 240).last!
        let coarse = run(Spring(period: 0.38, damping: 1), from: 0, to: 100, seconds: 0.5, frame: 0.05).last!
        #expect(abs(fine - coarse) < 1e-6)
        var x = 0.0, v = 0.0
        Spring(period: 0.3, damping: 1.4).step(&x, velocity: &v, toward: 1, dt: 3)  // overdamped too
        #expect(abs(x - 1) < 1e-3)
    }

    @Test func calmFollowNeverOvershoots() {
        let trace = run(Spring(period: 0.2, damping: 1), from: 0, to: 100, seconds: 1, frame: 1.0 / 120)
        #expect(trace.allSatisfy { $0 <= 100.0001 })
        #expect(abs(trace.last! - 100) < 0.1)
    }
}
