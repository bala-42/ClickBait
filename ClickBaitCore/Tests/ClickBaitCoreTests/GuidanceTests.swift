import Foundation
import Testing
@testable import ClickBaitCore

/// Guidance: the highlight (A) and arrow (B) on one API — alignment, resizing, label placement,
/// tip precision, tail clearance, stacking with priorities, armed clicks.
struct GuidanceTests {
    private let screen = Rect(x: 0, y: 0, width: 1512, height: 944)
    private let target = Rect(x: 400, y: 400, width: 200, height: 60)

    // MARK: Highlight — alignment and resizing

    @Test func theBoxHugsItsTargetWithPadding() {
        let box = Guidance.box(for: target, screen: screen)
        #expect(box == Rect(x: 394, y: 394, width: 212, height: 72))
    }

    @Test func itFollowsTheTargetWhenTheWindowResizes() {
        let resized = Rect(x: 520, y: 380, width: 260, height: 90)  // the same control after a resize
        let box = Guidance.box(for: resized, screen: screen)
        #expect(box.midX == resized.midX && box.midY == resized.midY)
        #expect(box.width == resized.width + 2 * Guidance.padding)
    }

    @Test func itScalesWithZoom() {
        let zoomed = Guidance.box(for: target, scale: 2, screen: screen)
        #expect(zoomed.width == target.width + 4 * Guidance.padding)
    }

    @Test func itStaysOnTheScreen() {
        let edge = Guidance.box(for: Rect(x: 1500, y: 930, width: 40, height: 40), screen: screen)
        #expect(edge.maxX <= screen.maxX && edge.maxY <= screen.maxY)
    }

    // MARK: Labels around the box

    @Test func theLabelGoesBelowWhenThereIsRoom() {
        let box = Guidance.box(for: target, screen: screen)
        let label = Guidance.label(size: (120, 24), around: box, screen: screen)
        #expect(label.maxY == box.minY - Guidance.labelGap)  // below (y up)
        #expect(abs(label.midX - box.midX) < 0.01)
    }

    @Test func theLabelMovesOffACriticalLabel() {
        let box = Guidance.box(for: target, screen: screen)
        let critical = Rect(x: 420, y: 340, width: 160, height: 40)  // right where "below" would go
        let label = Guidance.label(size: (120, 24), around: box, screen: screen, avoid: [critical])
        #expect(!Guidance.intersects(label, critical))
        #expect(!Guidance.intersects(label, box))
        #expect(label.minY >= box.maxY)  // above instead
    }

    @Test func theLabelNeverCoversTheBox() {
        let tight = Rect(x: 0, y: 0, width: 300, height: 120)  // a small screen
        let box = Guidance.box(for: Rect(x: 60, y: 30, width: 180, height: 60), screen: tight)
        let label = Guidance.label(size: (100, 20), around: box, screen: tight)
        #expect(Guidance.contains(tight, label))
    }

    // MARK: Arrow — tip precision and tail clearance

    @Test func theTipIsExactlyOnThePoint() {
        let point = Point(x: 700, y: 500)
        let layout = Guidance.layout([GuideSpec(kind: .arrow, point: point)], screen: screen)
        #expect(layout.first?.tip == point)
        let tail = layout.first!.tail!
        #expect(abs(hypot(tail.x - point.x, tail.y - point.y) - Guidance.arrowLength) < 0.001)
    }

    @Test func theTailTurnsAwayFromNearbyControls() {
        let tip = Point(x: 700, y: 500)
        let control = Rect(x: 620, y: 520, width: 60, height: 40)  // up-left of the tip, where the tail would go
        let (tail, _) = Guidance.arrow(tip: tip, avoid: [control], screen: screen)
        #expect(Guidance.distance(from: control, toSegment: tip, tail) >= Guidance.tailClearance)
    }

    @Test func theTailStaysOnTheScreen() {
        let corner = Point(x: 5, y: 940)  // top-left corner: up-left would leave the screen
        let (tail, _) = Guidance.arrow(tip: corner, screen: screen)
        #expect(Guidance.contains(screen, tail))
    }

    @Test func anArrowAtAnElementTouchesItsEdge() {
        let tip = Guidance.tip(for: target, screen: screen)
        let onEdge = abs(tip.x - target.minX) < 0.01 || abs(tip.x - target.maxX) < 0.01
            || abs(tip.y - target.minY) < 0.01 || abs(tip.y - target.maxY) < 0.01
        #expect(onEdge)
    }

    @Test func anArrowsLabelNeverSitsOnTheArrow() {
        // Pointing inside a highlight: every spot near it touches the box, but never the arrow.
        let box = GuideSpec(kind: .highlight, bounds: Rect(x: 600, y: 420, width: 300, height: 100), label: "Recent", priority: 1)
        let arrow = GuideSpec(kind: .arrow, point: Point(x: 750, y: 470), label: "Click here", priority: 2)
        let layout = Guidance.layout([box, arrow], screen: screen)[1]
        let shaft = Guidance.extent(layout.tip!, layout.tail!)
        #expect(!Guidance.intersects(layout.label!, shaft))
    }

    // MARK: Stacking and priority

    @Test func thePrimaryIsOnTopAtFullStrength() {
        let low = GuideSpec(kind: .highlight, bounds: target, label: "Recent", priority: 1)
        let high = GuideSpec(kind: .arrow, point: Point(x: 500, y: 430), label: "Click Share", priority: 5)
        let layouts = Guidance.layout([low, high], screen: screen)
        #expect(layouts[1].isPrimary && layouts[1].order == 1)
        #expect(!layouts[0].isPrimary && layouts[0].order == 0)
        #expect(layouts[1].opacity == 1)
        #expect(layouts[0].opacity == Guidance.dimmedOpacity)  // it overlaps the primary
    }

    @Test func guidesClearOfThePrimaryStayFull() {
        let a = GuideSpec(kind: .highlight, bounds: Rect(x: 50, y: 50, width: 100, height: 40), priority: 1)
        let b = GuideSpec(kind: .highlight, bounds: Rect(x: 900, y: 600, width: 100, height: 40), priority: 2)
        let layouts = Guidance.layout([a, b], screen: screen)
        #expect(layouts.allSatisfy { $0.opacity == 1 })
    }

    @Test func labelsNeverOverlapEachOther() {
        let a = GuideSpec(kind: .highlight, bounds: Rect(x: 400, y: 400, width: 120, height: 40), label: "First thing", priority: 2)
        let b = GuideSpec(kind: .highlight, bounds: Rect(x: 400, y: 460, width: 120, height: 40), label: "Second thing", priority: 1)
        let layouts = Guidance.layout([a, b], screen: screen)
        let labels = layouts.compactMap(\.label)
        #expect(labels.count == 2)
        #expect(!Guidance.intersects(labels[0], labels[1]))
    }

    @Test func aTieGoesToTheLatest() {
        let first = GuideSpec(kind: .highlight, bounds: target, priority: 3)
        let second = GuideSpec(kind: .highlight, bounds: target, priority: 3)
        #expect(Guidance.layout([first, second], screen: screen)[1].isPrimary)
    }

    // MARK: Armed clicks

    @Test func informationalGuidesCatchNothing() {
        let guide = GuideSpec(kind: .highlight, bounds: target)
        let layout = Guidance.layout([guide], screen: screen)[0]
        #expect(!Guidance.catches(Point(x: 500, y: 430), guide: guide, layout: layout))
    }

    @Test func anArmedHighlightCatchesClicksInsideOnly() {
        let guide = GuideSpec(kind: .highlight, bounds: target, armed: true)
        let layout = Guidance.layout([guide], screen: screen)[0]
        #expect(Guidance.catches(Point(x: 500, y: 430), guide: guide, layout: layout))
        #expect(!Guidance.catches(Point(x: 100, y: 100), guide: guide, layout: layout))
    }

    @Test func anArmedArrowCatchesItsElementOrNearItsTip() {
        let atElement = GuideSpec(kind: .arrow, bounds: target, armed: true)
        let elementLayout = Guidance.layout([atElement], screen: screen)[0]
        #expect(Guidance.catches(Point(x: 410, y: 410), guide: atElement, layout: elementLayout))
        let atPoint = GuideSpec(kind: .arrow, point: Point(x: 700, y: 500), armed: true)
        let pointLayout = Guidance.layout([atPoint], screen: screen)[0]
        #expect(Guidance.catches(Point(x: 708, y: 506), guide: atPoint, layout: pointLayout))
        #expect(!Guidance.catches(Point(x: 760, y: 560), guide: atPoint, layout: pointLayout))
    }
}
