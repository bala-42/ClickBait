import Foundation
import Testing
@testable import ClickBaitCore

struct FlightArcTests {
    private let origin = Point(x: 0, y: 0)

    @Test func longFlightsAreClickysArc() {
        let flight = FlightArc(from: origin, to: Point(x: 1000, y: 0))
        #expect(flight.height == 80)  // min(1000·0.2, 80)
        #expect(flight.swell == 0.3)
        #expect(flight.duration == 1.25)  // 1000 / 800
        #expect(flight.control == Point(x: 500, y: 80))  // the midpoint, raised (AppKit: y up)
    }

    @Test func durationIsClamped() {
        #expect(FlightArc.duration(forDistance: 100) == 0.6)
        #expect(FlightArc.duration(forDistance: 800) == 1.0)
        #expect(FlightArc.duration(forDistance: 4000) == 1.4)
    }

    @Test func shortHopsAreFlatAndGrowWithDistance() {
        let hop = FlightArc(from: origin, to: Point(x: 100, y: 0))
        #expect(hop.height == 0)
        #expect(hop.swell == 0)
        let medium = FlightArc(from: origin, to: Point(x: 260, y: 0))  // halfway between 120 and 400
        #expect(abs(medium.height - 26) < 1e-9)  // min(52, 80) · 0.5
        #expect(abs(medium.swell - 0.15) < 1e-9)
        #expect(FlightArc.arcShare(forDistance: 400) == 1)
        #expect(FlightArc.arcShare(forDistance: 120) == 0)
    }

    @Test func smoothstepStartsAndEndsGently() {
        #expect(FlightArc.smoothstep(0) == 0)
        #expect(FlightArc.smoothstep(0.5) == 0.5)
        #expect(FlightArc.smoothstep(1) == 1)
        #expect(FlightArc.smoothstep(0.1) < 0.1)
        #expect(FlightArc.smoothstep(1.5) == 1)
    }

    @Test func curveStartsAndEndsOnItsPoints() {
        let flight = FlightArc(from: Point(x: 10, y: 20), to: Point(x: 610, y: 220))
        #expect(flight.point(at: 0) == flight.start)
        #expect(flight.point(at: 1) == flight.end)
        let middle = flight.point(at: 0.5)
        #expect(abs(middle.y - (120 + flight.height / 2)) < 1e-9)  // a quadratic reaches half its control height
    }

    @Test func headingFollowsTheCurve() throws {
        let flight = FlightArc(from: origin, to: Point(x: 1000, y: 0))
        // Rising at the start (up-right), level at the top, falling at the end.
        let first = try #require(flight.heading(at: 0)), top = try #require(flight.heading(at: 0.5))
        let last = try #require(flight.heading(at: 1))
        #expect(first > 0 && first < 90)
        #expect(abs(top - 90) < 1e-9)
        #expect(last > 90 && last < 180)
        #expect(FlightArc(from: origin, to: origin).heading(at: 0.5) == nil)
    }

    @Test func swellAndGlowPeakMidway() {
        let flight = FlightArc(from: origin, to: Point(x: 1000, y: 0))
        #expect(flight.scale(at: 0) == 1)
        #expect(abs(flight.scale(at: 0.5) - 1.3) < 1e-9)
        #expect(abs(flight.scale(at: 1) - 1) < 1e-9)
        #expect(abs(flight.glowGrowth(at: 0.5) - 6) < 1e-9)  // (1.3 − 1) · 20
    }

    @Test func progressIsTimedByElapsedSeconds() {
        let flight = FlightArc(from: origin, to: Point(x: 800, y: 0))  // 1 s
        #expect(flight.progress(after: -1) == 0)
        #expect(flight.progress(after: 0.25) == 0.25)
        #expect(flight.progress(after: 5) == 1)
    }
}
