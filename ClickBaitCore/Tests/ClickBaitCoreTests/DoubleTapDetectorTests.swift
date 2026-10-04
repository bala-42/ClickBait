import Testing
@testable import ClickBaitCore

struct DoubleTapDetectorTests {
    @Test func singleTapIsFirst() {
        var detector = DoubleTapDetector()
        #expect(detector.tap(at: 10) == .first)
    }

    @Test func secondTapWithinWindowIsSecond() {
        var detector = DoubleTapDetector()
        _ = detector.tap(at: 10)
        #expect(detector.tap(at: 10.25) == .second)
    }

    @Test func tapExactlyAtWindowStillCounts() {
        // Binary-exact values: 1.3 - 1 is 0.30000000000000004 in floating point.
        var detector = DoubleTapDetector(window: 0.5)
        _ = detector.tap(at: 1)
        #expect(detector.tap(at: 1.5) == .second)
    }

    @Test func slowSecondTapStartsOver() {
        var detector = DoubleTapDetector()
        _ = detector.tap(at: 10)
        #expect(detector.tap(at: 10.5) == .first)
        // ...and that late tap can itself be the start of a double tap.
        #expect(detector.tap(at: 10.7) == .second)
    }

    @Test func thirdTapStartsOver() {
        var detector = DoubleTapDetector()
        _ = detector.tap(at: 10)
        _ = detector.tap(at: 10.1)
        #expect(detector.tap(at: 10.2) == .first)
    }

    @Test func resetForgetsTheFirstTap() {
        var detector = DoubleTapDetector()
        _ = detector.tap(at: 10)
        detector.reset()
        #expect(detector.tap(at: 10.1) == .first)
    }
}
