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
}
