import Testing
@testable import ClickBaitCore

struct CompanionPlacementTests {
    private let screen = Rect(x: 0, y: 0, width: 1512, height: 944)
    private let content = (width: 60.0, height: 40.0)
    private let offset = (width: 35.0, height: 25.0)
    private let inContent = 20.0

    private func side(_ x: Double, _ y: Double, _ current: CompanionPlacement.Side) -> CompanionPlacement.Side {
        CompanionPlacement.side(mouse: Point(x: x, y: y), content: content, bounds: screen, offset: offset,
                                inContent: inContent, current: current)
    }

    private func topLeft(_ x: Double, _ y: Double, blend: (x: Double, y: Double)) -> Point {
        CompanionPlacement.topLeft(mouse: Point(x: x, y: y), content: content, bounds: screen, offset: offset,
                                   inContent: inContent, blend: blend)
    }

    /// The right edge's threshold: where the content's right side reaches the screen's.
    private var rightThreshold: Double { screen.maxX - (offset.width - inContent + content.width) }

    @Test func awayFromEdgesTheTriangleSitsBelowRight() {
        let corner = topLeft(700, 500, blend: (0, 0))
        #expect(corner.x + inContent == 735)  // triangle 35 right
        #expect(corner.y - inContent == 475)  // and 25 below
        #expect(side(700, 500, .init()) == .init())
    }

    @Test func theFlipIsTheMirrorSpotNotTheWholeBox() {
        let corner = topLeft(700, 500, blend: (1, 1))
        #expect(corner.x + inContent == 665)  // triangle 35 left: 70 pt in all
        #expect(corner.y - inContent == 525)  // and 25 above
    }

    @Test func atTheRightEdgeItFlipsLeft() {
        #expect(!side(rightThreshold, 500, .init()).left)
        #expect(side(rightThreshold + 1, 500, .init()).left)
    }

    /// The jitter: a cursor wobbling 1 pt either side of the line flipped it every frame.
    @Test func wobblingAtTheLineFlipsOnce() {
        var current = CompanionPlacement.Side()
        var flips = 0
        for x in [rightThreshold + 1, rightThreshold - 1, rightThreshold + 1, rightThreshold - 1, rightThreshold, rightThreshold - 2] {
            let next = side(x, 500, current)
            if next.left != current.left { flips += 1 }
            current = next
        }
        #expect(flips == 1)
        #expect(current.left)
    }

    @Test func itComesBackOnlyWithRoomToSpare() {
        let left = CompanionPlacement.Side(left: true)
        #expect(side(rightThreshold - CompanionPlacement.margin + 1, 500, left).left)
        #expect(!side(rightThreshold - CompanionPlacement.margin, 500, left).left)
    }

    @Test func theBottomEdgeBehavesTheSame() {
        let threshold = screen.minY + offset.height - inContent + content.height
        var current = side(700, threshold - 1, .init())
        #expect(current.above)
        current = side(700, threshold + 1, current)
        #expect(current.above)
        current = side(700, threshold + CompanionPlacement.margin, current)
        #expect(!current.above)
    }

    /// Not snappy: the side change takes `flipTime`, smoothly, no overshoot, no jump.
    @Test func theFlipGlides() {
        var blend = 0.0, last = topLeft(700, 500, blend: (0, 0)).x, frames = 0
        while blend < 1 {
            blend = CompanionPlacement.step(blend, toward: true, dt: 1.0 / 60, reduceMotion: false)
            let x = topLeft(700, 500, blend: (blend, 0)).x
            #expect(x <= last)  // always toward the mirror spot: no overshoot
            #expect(last - x <= 70 * 0.1)  // never more than a tenth of the way in one frame
            last = x
            frames += 1
        }
        #expect(abs(Double(frames) / 60 - CompanionPlacement.flipTime) < 0.02)
        #expect(CompanionPlacement.step(0, toward: true, dt: 1.0 / 60, reduceMotion: true) == 1)
    }

    @Test func itNeverLeavesTheScreen() {
        for (x, y) in [(0.0, 0.0), (1512.0, 944.0), (1512.0, 0.0), (0.0, 944.0)] {
            for blend in [(0.0, 0.0), (1.0, 1.0), (0.5, 0.5)] {
                let corner = topLeft(x, y, blend: blend)
                #expect(corner.x >= screen.minX && corner.x + content.width <= screen.maxX)
                #expect(corner.y <= screen.maxY && corner.y - content.height >= screen.minY)
            }
        }
    }
}
