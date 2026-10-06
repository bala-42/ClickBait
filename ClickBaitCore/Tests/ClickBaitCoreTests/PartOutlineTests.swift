import Foundation
import Testing
@testable import ClickBaitCore

struct PartOutlineTests {
    /// A dark 200×100 RGBA image with filled discs (centre x, centre y, radius, grey level).
    private func image(_ discs: [(Double, Double, Double, UInt8)]) -> [UInt8] {
        var pixels = [UInt8](repeating: 10, count: 200 * 100 * 4)
        for y in 0..<100 {
            for x in 0..<200 {
                for (cx, cy, r, level) in discs where (Double(x) + 0.5 - cx) * (Double(x) + 0.5 - cx) + (Double(y) + 0.5 - cy) * (Double(y) + 0.5 - cy) <= r * r {
                    let i = (y * 200 + x) * 4
                    pixels[i] = level; pixels[i + 1] = level; pixels[i + 2] = level
                }
            }
        }
        return pixels
    }

    private let marked = Rect(x: 0, y: 0, width: 200, height: 100)

    @Test func findsTheEdgeOfASeparateThing() throws {
        let pixels = image([(50, 50, 10, 200), (120, 50, 6, 150)])
        let outline = try #require(PartOutline.find(rgba: pixels, width: 200, height: 100, bytesPerRow: 800,
                                                    at: Point(x: 50, y: 50), marked: marked))
        for radius in outline.radii { #expect(abs(radius - 10) <= 1.5) }
        // The small one next to it is its own thing.
        let small = try #require(PartOutline.find(rgba: pixels, width: 200, height: 100, bytesPerRow: 800,
                                                  at: Point(x: 120, y: 50), marked: marked))
        #expect(small.radii.allSatisfy { abs($0 - 6) <= 1.5 })
    }

    @Test func anOffCentrePointIsNearerOneEdge() throws {
        let pixels = image([(50, 50, 10, 200)])
        let outline = try #require(PartOutline.find(rgba: pixels, width: 200, height: 100, bytesPerRow: 800,
                                                    at: Point(x: 56, y: 50), marked: marked))
        #expect(outline.radius(toward: 1, 0) < 5)   // right: the near edge
        #expect(outline.radius(toward: -1, 0) > 14) // left: across the disc
    }

    @Test func noOutlineOnTheBackgroundOrInsideSomethingLarge() {
        let pixels = image([(50, 50, 10, 200)])
        #expect(PartOutline.find(rgba: pixels, width: 200, height: 100, bytesPerRow: 800,
                                 at: Point(x: 150, y: 20), marked: marked) == nil)
        // A shape covering most of the marked area: the point is a part of it, not a thing.
        let big = image([(100, 50, 80, 200)])
        #expect(PartOutline.find(rgba: big, width: 200, height: 100, bytesPerRow: 800,
                                 at: Point(x: 100, y: 50), marked: marked) == nil)
        #expect(PartOutline.find(rgba: pixels, width: 200, height: 100, bytesPerRow: 800,
                                 at: Point(x: 250, y: 50), marked: marked) == nil)
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

    @Test func imageUpIsScreenUp() throws {
        // A tall thin bar above the point (in the image, rows run down): the up radius is long.
        var pixels = [UInt8](repeating: 10, count: 200 * 100 * 4)
        for y in 20...60 { for x in 48...52 { let i = (y * 200 + x) * 4; pixels[i] = 200; pixels[i + 1] = 200; pixels[i + 2] = 200 } }
        let outline = try #require(PartOutline.find(rgba: pixels, width: 200, height: 100, bytesPerRow: 800,
                                                    at: Point(x: 50, y: 58), marked: marked))
        #expect(outline.radius(toward: 0, 1) > 30)  // up on screen = toward row 20
        #expect(outline.radius(toward: 0, -1) < 4)
    }
}
