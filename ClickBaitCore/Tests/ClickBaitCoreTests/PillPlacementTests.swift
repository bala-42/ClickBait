import Testing
@testable import ClickBaitCore

struct PillPlacementTests {
    // A 1512×944 visible area starting at y 38 (the Dock below, the menu bar above).
    private let screen = Rect(x: 0, y: 38, width: 1512, height: 944)

    @Test func besideTheTriangleWhenThereIsRoom() {
        let spot = PillPlacement.beside(Point(x: 600, y: 500), width: 120, height: 30, gap: 12, preferRight: true, bounds: screen)
        #expect(spot.x == 612 && spot.top == 515)
    }

    @Test func switchesSidesAtTheRightEdge() {
        let spot = PillPlacement.beside(Point(x: 1480, y: 500), width: 120, height: 30, gap: 12, preferRight: true, bounds: screen)
        #expect(spot.x == 1348)  // to the triangle's left, fully on screen
    }

    @Test func staysBelowTheMenuBarAndAboveTheDock() {
        let top = PillPlacement.beside(Point(x: 600, y: 990), width: 120, height: 30, gap: 12, preferRight: true, bounds: screen)
        #expect(top.top == 978)  // 982 − 4
        let bottom = PillPlacement.beside(Point(x: 600, y: 30), width: 120, height: 30, gap: 12, preferRight: true, bounds: screen)
        #expect(bottom.top - 30 == 42)  // 38 + 4
    }

    @Test func aWidePillIsPushedInside() {
        let spot = PillPlacement.beside(Point(x: 100, y: 500), width: 300, height: 30, gap: 12, preferRight: false, bounds: screen)
        #expect(spot.x >= 4 && spot.x + 300 <= 1508)
    }
}
