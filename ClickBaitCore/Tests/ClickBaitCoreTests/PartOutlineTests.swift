import Foundation
import Testing
@testable import ClickBaitCore

struct PartOutlineTests {
    /// A 200×100 mask with filled discs (centre x, centre y, radius).
    private func mask(_ discs: [(Double, Double, Double)]) -> [Bool] {
        (0..<(200 * 100)).map { index in
            let x = Double(index % 200) + 0.5, y = Double(index / 200) + 0.5
            return discs.contains { (x - $0.0) * (x - $0.0) + (y - $0.1) * (y - $0.1) <= $0.2 * $0.2 }
        }
    }

    @Test func measuresTheEdgeAllRound() {
        let outline = PartOutline.from(mask: mask([(50, 50, 10)]), width: 200, height: 100, seed: Point(x: 50, y: 50))
        #expect(outline.radii.count == PartOutline.directions)
        for radius in outline.radii { #expect(abs(radius - 10) <= 1) }
    }

    @Test func anOffCentrePointIsNearerOneEdge() {
        let outline = PartOutline.from(mask: mask([(50, 50, 10)]), width: 200, height: 100, seed: Point(x: 56, y: 50))
        #expect(outline.radius(toward: 1, 0) < 5)   // right: the near edge
        #expect(outline.radius(toward: -1, 0) > 14) // left: across the disc
    }

    @Test func stopsAtTheImageEdge() {
        // A disc cut off by the left edge of the image (like the Sun in a solar-system picture).
        let outline = PartOutline.from(mask: mask([(5, 50, 30)]), width: 200, height: 100, seed: Point(x: 10, y: 50))
        #expect(outline.radius(toward: -1, 0) <= 10)
        #expect(outline.radius(toward: 1, 0) > 20)
    }

    @Test func directionsUseScreenAxes() {
        // Direction 4 of 16 is straight up (y up), 12 straight down.
        var radii = [Double](repeating: 5, count: PartOutline.directions)
        radii[4] = 9
        let outline = PartOutline(radii: radii)
        #expect(outline.radius(toward: 0, 1) == 9)
        #expect(outline.radius(toward: 0, -1) == 5)
        #expect(abs(outline.radius(toward: cos(.pi * 7 / 16), sin(.pi * 7 / 16)) - 7) < 0.001)  // halfway to "up"
        #expect(outline.scaled(by: 0.5).radii[4] == 4.5)
    }

    @Test func imageUpIsScreenUp() {
        // A tall thin bar above the point (in the image, rows run down): the up radius is long.
        var bar = [Bool](repeating: false, count: 200 * 100)
        for y in 20...60 { for x in 48...52 { bar[y * 200 + x] = true } }
        let outline = PartOutline.from(mask: bar, width: 200, height: 100, seed: Point(x: 50, y: 58))
        #expect(outline.radius(toward: 0, 1) > 30)  // up on screen = toward row 20
        #expect(outline.radius(toward: 0, -1) < 4)
    }
}
