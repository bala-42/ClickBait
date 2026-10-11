import Testing
@testable import ClickBaitCore

struct GuideTimingTests {
    @Test func arrivesOnlyWhenFlownThereAndAimed() {
        #expect(!GuideTiming.hasArrived(flightProgress: 0, distanceToSpot: 400, isTurning: false))  // the first frame
        #expect(!GuideTiming.hasArrived(flightProgress: 0.9, distanceToSpot: 3, isTurning: false))
        #expect(!GuideTiming.hasArrived(flightProgress: 1, distanceToSpot: 0, isTurning: true))   // still turning on
        #expect(!GuideTiming.hasArrived(flightProgress: 1, distanceToSpot: 2, isTurning: false))
        #expect(GuideTiming.hasArrived(flightProgress: 1, distanceToSpot: 0, isTurning: false))
        #expect(GuideTiming.hasArrived(flightProgress: nil, distanceToSpot: 0.2, isTurning: false))  // Reduce Motion: no flight
    }

    @Test func holdsAfterArriving() {
        #expect(GuideTiming.hold(isTour: false, isTutorial: false, targetCount: 1) == 3)
        #expect(GuideTiming.hold(isTour: false, isTutorial: false, targetCount: 2) == 2)
        #expect(GuideTiming.hold(isTour: true, isTutorial: false, targetCount: 6) == 2.4)
        #expect(GuideTiming.hold(isTour: false, isTutorial: true, targetCount: 3) == nil)  // waits for a click
    }

    @Test func theSafetyCapNeverCutsANormalStopShort() {
        let longestFlight = FlightArc.duration(forDistance: 10_000)
        #expect(GuideTiming.maxStop > longestFlight + 1 + GuideTiming.singlePointHold)
    }
}
