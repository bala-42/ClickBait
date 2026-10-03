import Foundation
import Testing
@testable import ClickBaitCore

struct SnipTrackerTests {
    @Test func stillTapIsATap() {
        var tracker = SnipTracker(start: Point(x: 100, y: 100))
        tracker.cursorMoved(to: Point(x: 103, y: 101))
        #expect(tracker.decide() == .tap)
    }

    @Test func circleBecomesACircledSnipWithItsBounds() {
        var tracker = SnipTracker(start: Point(x: 200, y: 100))
        for step in 0...36 {
            let angle = Double(step) / 36 * 2 * .pi
            tracker.cursorMoved(to: Point(x: 200 + 50 * cos(angle), y: 100 + 30 * sin(angle)))
        }
        guard case .snip(let kind, let region, let path) = tracker.decide() else {
            Issue.record("expected a snip"); return
        }
        #expect(kind == .circled)
        #expect(abs(region.x - 150) < 1 && abs(region.width - 100) < 1)
        #expect(abs(region.y - 70) < 1 && abs(region.height - 60) < 1)
        #expect(path.count > 30)
    }

    @Test func shortDriftIsATap() {
        var tracker = SnipTracker(start: Point(x: 0, y: 0))
        tracker.cursorMoved(to: Point(x: 25, y: 0))
        #expect(tracker.decide() == .tap)
        #expect(!tracker.isMarking || tracker.traceLength < SnipTracker.minTraceLength)
    }

    @Test func dragMakesABoxAndDropsTheTrace() {
        var tracker = SnipTracker(start: Point(x: 0, y: 0))
        for x in stride(from: 0.0, through: 300, by: 10) { tracker.cursorMoved(to: Point(x: x, y: 0)) }
        tracker.mouseDown(at: Point(x: 300, y: 200))
        tracker.mouseDragged(to: Point(x: 250, y: 120))
        tracker.cursorMoved(to: Point(x: 900, y: 900))  // ignored once boxing
        tracker.mouseDragged(to: Point(x: 100, y: 80))
        #expect(tracker.decide() == .snip(.boxed, region: Rect(x: 100, y: 80, width: 200, height: 120), path: [
            Point(x: 100, y: 80), Point(x: 300, y: 80), Point(x: 300, y: 200), Point(x: 100, y: 200),
        ]))
    }

    @Test func clickWithoutDragIsATap() {
        var tracker = SnipTracker(start: Point(x: 0, y: 0))
        tracker.mouseDown(at: Point(x: 50, y: 50))
        tracker.mouseDragged(to: Point(x: 53, y: 52))
        #expect(tracker.decide() == .tap)
    }

    @Test func sidewaysSlipIsNotABox() {
        // Real drag from testing: 109×1 pt.
        var tracker = SnipTracker(start: Point(x: 0, y: 0))
        tracker.mouseDown(at: Point(x: 10, y: 10))
        tracker.mouseDragged(to: Point(x: 119, y: 11))
        #expect(tracker.decide() == .tap)
    }

    @Test func thinBoxStillCounts() {
        // Boxing one line of text: wide but short.
        var tracker = SnipTracker(start: Point(x: 0, y: 0))
        tracker.mouseDown(at: Point(x: 10, y: 10))
        tracker.mouseDragged(to: Point(x: 400, y: 18))
        guard case .snip(.boxed, _, _) = tracker.decide() else { Issue.record("expected a box"); return }
    }
}

struct SnipLayoutTests {
    @Test func padsAroundTheRegion() {
        let crop = SnipLayout.crop(around: Rect(x: 500, y: 400, width: 400, height: 300), displayWidth: 1920, displayHeight: 1080)
        // 15% of 400 = 60 pt on every side.
        #expect(crop == Rect(x: 440, y: 340, width: 520, height: 420))
    }

    @Test func tinyRegionsAreWidenedAroundTheirCenter() {
        let crop = SnipLayout.crop(around: Rect(x: 990, y: 490, width: 20, height: 20), displayWidth: 1920, displayHeight: 1080)
        #expect(crop == Rect(x: 860, y: 360, width: 280, height: 280))
    }

    @Test func staysInsideTheDisplay() {
        let crop = SnipLayout.crop(around: Rect(x: 0, y: 1000, width: 100, height: 80), displayWidth: 1920, displayHeight: 1080)
        #expect(crop.x == 0)
        #expect(crop.y + crop.height == 1080)
        let whole = SnipLayout.crop(around: Rect(x: 0, y: 0, width: 1920, height: 1080), displayWidth: 1920, displayHeight: 1080)
        #expect(whole == Rect(x: 0, y: 0, width: 1920, height: 1080))
    }
}

struct SnipPromptTests {
    @Test func snipPromptDescribesTheCloseUp() {
        let request = AskRequest(question: "", screenshotJPEG: .init(), screenshotWidth: 600, screenshotHeight: 400,
                                 context: ScreenContext(appName: "Safari"), snip: .circled)
        let text = Prompt.userText(for: request)
        #expect(text.contains("close-up of the part of the screen the user circled"))
        #expect(text.hasSuffix("Explain what's inside the red outline."))
    }
}
