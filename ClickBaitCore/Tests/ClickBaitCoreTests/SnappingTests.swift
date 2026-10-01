import Testing
@testable import ClickBaitCore

struct LabelMatcherTests {
    @Test func exactAfterNormalizing() {
        #expect(LabelMatcher.similarity("Share", "share") == 1)
        #expect(LabelMatcher.similarity("Share button", "Share") >= 0.85)  // "button" is filler
        #expect(LabelMatcher.similarity("Export…", "Export") == 1)
    }

    @Test func containmentScoresHigh() {
        #expect(LabelMatcher.similarity("Copy", "Copy Link") >= 0.7)
    }

    @Test func typosStillMatch() {
        #expect(LabelMatcher.similarity("Setings", "Settings") >= 0.8)
    }

    @Test func unrelatedScoresLow() {
        #expect(LabelMatcher.similarity("Share", "Delete") < 0.5)
        #expect(LabelMatcher.similarity("Share", "") == 0)
        #expect(LabelMatcher.similarity("button", "Share") < 0.5)  // only filler words
        #expect(LabelMatcher.similarity("Copy Link", "Copy Link") > LabelMatcher.similarity("Copy Link", "Copy"))
    }
}

struct SnapperTests {
    private let share = SnapCandidate(role: "AXButton", label: "Share", frame: Rect(x: 1470, y: 40, width: 40, height: 30))
    private let delete = SnapCandidate(role: "AXButton", label: "Delete", frame: Rect(x: 1420, y: 40, width: 40, height: 30))

    @Test func snapsToTheMatchingElementNearby() {
        // The model pointed 20 pt left of the Share button, onto Delete's edge.
        let decision = Snapper.decide(target: Point(x: 1455, y: 55), label: "Share button", candidates: [share, delete])
        #expect(decision.candidate == share)
        #expect(decision.point == Point(x: 1490, y: 55))
        #expect(decision.reason == .labelMatch)
    }

    @Test func ignoresMatchesBeyondTheRadius() {
        let decision = Snapper.decide(target: Point(x: 1300, y: 55), label: "Share", candidates: [share])
        #expect(decision.candidate == nil)
        #expect(decision.point == Point(x: 1300, y: 55))
        #expect(decision.reason == .noCandidates)
    }

    @Test func centersOnTheContainingElementWhenNoLabelMatches() {
        let icon = SnapCandidate(role: "AXButton", label: "", frame: Rect(x: 100, y: 100, width: 20, height: 20))
        let decision = Snapper.decide(target: Point(x: 103, y: 117), label: "Sidebar toggle", candidates: [icon])
        #expect(decision.point == Point(x: 110, y: 110))
        #expect(decision.reason == .containingElement)
    }

    @Test func prefersTheSmallestContainingElement() {
        let toolbar = SnapCandidate(role: "AXButton", label: "", frame: Rect(x: 0, y: 0, width: 500, height: 60))
        let button = SnapCandidate(role: "AXButton", label: "", frame: Rect(x: 90, y: 10, width: 30, height: 30))
        let decision = Snapper.decide(target: Point(x: 100, y: 20), label: "Gear", candidates: [toolbar, button])
        #expect(decision.candidate == button)
    }

    @Test func staysPutWhenNothingMatchesAndItIsNotOnAnElement() {
        let decision = Snapper.decide(target: Point(x: 1455, y: 90), label: "Share", candidates: [delete])
        #expect(decision.point == Point(x: 1455, y: 90))
        #expect(decision.reason == .noConfidentMatch)
    }

    @Test func betterLabelBeatsCloserElement() {
        let copy = SnapCandidate(role: "AXButton", label: "Copy", frame: Rect(x: 200, y: 200, width: 40, height: 20))
        let copyLink = SnapCandidate(role: "AXButton", label: "Copy Link", frame: Rect(x: 200, y: 230, width: 80, height: 20))
        let decision = Snapper.decide(target: Point(x: 220, y: 210), label: "Copy Link", candidates: [copy, copyLink])
        #expect(decision.candidate == copyLink)
    }

    @Test func distanceIsZeroInsideAndEuclideanOutside() {
        let rect = Rect(x: 0, y: 0, width: 10, height: 10)
        #expect(Snapper.distance(from: Point(x: 5, y: 5), to: rect) == 0)
        #expect(Snapper.distance(from: Point(x: 13, y: 14), to: rect) == 5)
    }
}
