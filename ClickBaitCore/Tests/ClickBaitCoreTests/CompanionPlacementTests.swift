import Testing
@testable import ClickBaitCore

struct CompanionPlacementTests {
    private let screen = Rect(x: 0, y: 0, width: 1512, height: 945)
    private let content = (width: 120.0, height: 40.0)
    private let offset = (width: 35.0, height: 25.0)

    private func corner(_ x: Double, _ y: Double) -> Point {
        CompanionPlacement.topLeft(mouse: Point(x: x, y: y), content: content, bounds: screen, offset: offset, inContent: 10)
    }

    @Test func restsRightOfAndBelowTheCursor() {
        #expect(corner(600, 500) == Point(x: 625, y: 485))
    }

    /// At an edge it stops there, still right of and below as far as the screen allows,
    /// never on the cursor's other side.
    @Test func stopsAtTheEdgesInsteadOfFlipping() {
        #expect(corner(1500, 500).x == 1512 - 120)
        #expect(corner(600, 10).y == 40)
        #expect(corner(-50, 990) == Point(x: 0, y: 945))
    }
}
