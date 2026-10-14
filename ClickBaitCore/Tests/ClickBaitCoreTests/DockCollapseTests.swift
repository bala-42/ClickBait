import Testing
@testable import ClickBaitCore

struct DockCollapseTests {
    private let visible = Rect(x: 0, y: 0, width: 1512, height: 944)

    @Test func handleSitsAgainstTheEdgeLevelWithTheTopTile() throws {
        let handle = DockCollapse.handle(in: visible)
        let top = try #require(AgentDock.tile(0, in: visible))
        #expect(handle.maxX == visible.maxX - DockCollapse.handleEdgeInset)
        #expect(handle.midY == top.midY)
        // Clear of the tiles' column: it covers nothing the dock didn't.
        #expect(handle.minX > top.maxX)
    }

    @Test func shakeZoneHoldsTheHandle() {
        let zone = DockCollapse.shakeZone(in: visible)
        let handle = DockCollapse.handle(in: visible)
        func holds(_ x: Double, _ y: Double) -> Bool { x >= zone.minX && x <= zone.maxX && y >= zone.minY && y <= zone.maxY }
        #expect(holds(handle.midX, handle.midY))
        #expect(!holds(visible.midX, visible.midY))
    }

    @Test func handleColourSaysWhatsWaiting() {
        #expect(DockCollapse.handleDot([(.done, false), (.working, false)]) == .azure)
        #expect(DockCollapse.handleDot([(.done, true), (.done, false)]) == .aquaGreen)
        #expect(DockCollapse.handleDot([(.done, true), (.failed, false)]) == .grey)
    }

    @Test func foldsOnlyWhenLeftAlone() {
        #expect(DockCollapse.foldsWhenIdle(cardOpen: false, pointerOver: false, idleFor: 4))
        #expect(!DockCollapse.foldsWhenIdle(cardOpen: false, pointerOver: false, idleFor: 3.9))
        #expect(!DockCollapse.foldsWhenIdle(cardOpen: true, pointerOver: false, idleFor: 60))
        #expect(!DockCollapse.foldsWhenIdle(cardOpen: false, pointerOver: true, idleFor: 60))
    }

    @Test func aClickElsewhereFoldsUnlessACardIsOpen() {
        #expect(DockCollapse.foldsOnClick(cardOpen: false, insideDock: false))
        #expect(!DockCollapse.foldsOnClick(cardOpen: true, insideDock: false))
        #expect(!DockCollapse.foldsOnClick(cardOpen: false, insideDock: true))
    }
}

struct ShakeDetectorTests {
    /// Moves along `xs`, one every `step` seconds; the times a shake was seen.
    private func feed(_ xs: [Double], step: Double = 0.05, into detector: inout ShakeDetector) -> [Int] {
        xs.enumerated().compactMap { index, x in detector.add(x: x, at: Double(index) * step) ? index : nil }
    }

    @Test func aWiggleIsAShake() {
        var detector = ShakeDetector()
        #expect(feed([0, 20, 0, 20, 0], into: &detector) == [4])
    }

    @Test func smallJitterIsNot() {
        var detector = ShakeDetector()
        #expect(feed([0, 8, 0, 8, 0, 8, 0, 8], into: &detector).isEmpty)
    }

    @Test func aSlowWiggleIsNot() {
        var detector = ShakeDetector()
        #expect(feed([0, 20, 0, 20, 0], step: 0.3, into: &detector).isEmpty)
    }

    @Test func aStraightSweepIsNot() {
        var detector = ShakeDetector()
        #expect(feed(Array(stride(from: 0.0, through: 300, by: 15)), into: &detector).isEmpty)
    }

    @Test func turnsAreMeasuredFromTheFarthestPoint() {
        var detector = ShakeDetector()
        // Out to 40, back only 10 (not a turn), back to 25 (a turn: 15 from 40)…
        #expect(feed([0, 40, 30, 25, 45, 30], into: &detector) == [5])
    }

    @Test func itStartsOverAfterAShake() {
        var detector = ShakeDetector()
        #expect(feed([0, 20, 0, 20, 0, 20, 0], into: &detector) == [4])
    }
}
