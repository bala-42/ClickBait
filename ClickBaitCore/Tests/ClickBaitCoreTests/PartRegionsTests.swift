import Foundation
import Testing
@testable import ClickBaitCore

/// Small synthetic pictures, drawn pixel by pixel (no stock images in tests).
private struct Canvas {
    var width: Int, height: Int
    var rgb: [UInt8]

    init(_ width: Int, _ height: Int, fill: (UInt8, UInt8, UInt8) = (255, 255, 255)) {
        self.width = width
        self.height = height
        rgb = Array((0..<(width * height)).flatMap { _ in [fill.0, fill.1, fill.2] })
    }

    mutating func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: (UInt8, UInt8, UInt8)) {
        for y in max(0, y0)..<min(height, y1) { for x in max(0, x0)..<min(width, x1) { set(x, y, c) } }
    }

    mutating func frame(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: (UInt8, UInt8, UInt8) = (0, 0, 0)) {
        rect(x0, y0, x1, y0 + 1, c); rect(x0, y1 - 1, x1, y1, c); rect(x0, y0, x0 + 1, y1, c); rect(x1 - 1, y0, x1, y1, c)
    }

    mutating func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        let i = (y * width + x) * 3
        rgb[i] = c.0; rgb[i + 1] = c.1; rgb[i + 2] = c.2
    }

    var image: PixelImage { PixelImage(width: width, height: height, rgb: rgb) }
    var all: Rect { Rect(x: 0, y: 0, width: Double(width), height: Double(height)) }
}

struct PartRegionsTests {
    /// A beige body (most of the picture) with three touching organs outlined in black.
    private func organs() -> Canvas {
        var canvas = Canvas(160, 200)
        canvas.rect(20, 10, 140, 190, (245, 205, 160))     // the body: a silhouette
        canvas.rect(40, 40, 80, 90, (200, 60, 70))         // "liver", dark red
        canvas.rect(80, 40, 120, 90, (90, 130, 220))       // "stomach", blue
        canvas.rect(50, 90, 110, 150, (110, 190, 90))      // "intestine", green
        canvas.frame(40, 40, 80, 90); canvas.frame(80, 40, 120, 90); canvas.frame(50, 90, 110, 150)
        return canvas
    }

    @Test func oneBlobNeverStandsInForManyParts() {
        let marked = Rect(x: 0, y: 0, width: 717, height: 1080)
        let body = FoundObject(center: Point(x: 350, y: 600), width: 500, height: 900, fill: 0.6)
        #expect(!PartRegions.objectsAreUsable([body], nameCount: 8, marked: marked))
        let planets = (0..<8).map { FoundObject(center: Point(x: Double(50 + $0 * 80), y: 300), width: 40, height: 40, fill: 0.8) }
        #expect(PartRegions.objectsAreUsable(planets, nameCount: 9, marked: marked))
        #expect(!PartRegions.objectsAreUsable(Array(planets.prefix(3)), nameCount: 9, marked: marked))  // far fewer than named
    }

    @Test func touchingColouredPartsBecomeSeparateMarks() {
        let canvas = organs()
        let marks = PartRegions.colourRegions(canvas.image, marked: canvas.all)
        #expect(marks.count == 3)  // the body is a silhouette, not a part
        let centres = marks.map(\.object.center)
        #expect(centres.contains { $0.x > 40 && $0.x < 80 && $0.y > 40 && $0.y < 90 })
        #expect(centres.contains { $0.x > 80 && $0.x < 120 && $0.y > 40 && $0.y < 90 })
        #expect(centres.contains { $0.x > 50 && $0.x < 110 && $0.y > 90 && $0.y < 150 })
        #expect(marks.allSatisfy { $0.outline != nil })
        #expect(marks.map(\.object.center.x) == marks.map(\.object.center.x).sorted())  // left to right
    }

    @Test func aStrokeAcrossOnePartDoesntSplitIt() {
        var canvas = Canvas(120, 120)
        canvas.rect(20, 20, 100, 100, (200, 80, 90))
        canvas.rect(20, 59, 100, 61, (0, 0, 0))  // a line drawn across it
        let marks = PartRegions.colourRegions(canvas.image, marked: canvas.all)
        #expect(marks.count == 1)
    }

    @Test func outlinesReachTheRegionsEdge() throws {
        var canvas = Canvas(120, 120)
        canvas.rect(30, 30, 90, 90, (80, 160, 220))
        let mark = try #require(PartRegions.colourRegions(canvas.image, marked: canvas.all).first)
        #expect(abs(mark.object.center.x - 60) <= 1.5 && abs(mark.object.center.y - 60) <= 1.5)
        let outline = try #require(mark.outline)
        #expect(abs(outline.radius(toward: 1, 0) - 30) <= 2)   // to the right edge
        #expect(abs(outline.radius(toward: 0, 1) - 30) <= 2)   // up
    }

    @Test func lineDrawingsSplitIntoTheirClosedShapes() {
        var canvas = Canvas(200, 120)
        canvas.frame(10, 10, 60, 60); canvas.frame(70, 10, 120, 60); canvas.frame(130, 10, 190, 110)
        canvas.rect(10, 80, 60, 81, (0, 0, 0))  // an open stroke: no shape
        let marks = PartRegions.lineRegions(canvas.image, marked: canvas.all)
        #expect(marks.count == 3)
        #expect(marks.map { Int($0.object.center.x / 10) } == [3, 9, 16])
    }

    @Test func theGridCoversWhatWasMarked() {
        let canvas = Canvas(200, 400)
        let marks = PartRegions.grid(canvas.image, marked: canvas.all)
        #expect(marks.count == 4 * 6)  // 4 across the short side, 400/200 × 4 = 8 → capped at 6
        #expect(marks.first?.object.center == Point(x: 25, y: 400.0 / 12))
    }

    @Test func measuresTellPictureKindsApart() {
        let coloured = organs()
        let colouredMeasures = PartRegions.measures(coloured.image, marked: coloured.all)
        #expect(colouredMeasures.colourVariety >= 3)
        var lines = Canvas(200, 120)
        lines.frame(10, 10, 60, 60); lines.frame(70, 10, 120, 60); lines.frame(130, 10, 190, 110)
        let lineMeasures = PartRegions.measures(lines.image, marked: lines.all)
        #expect(lineMeasures.colourVariety == 0)
        #expect(lineMeasures.strokeDensity > 0.015)
        #expect(PartRegions.methods(objectsUsable: false, measures: colouredMeasures).first == .colourRegions)
        #expect(PartRegions.methods(objectsUsable: false, measures: lineMeasures) == [.lineRegions, .grid])
        #expect(PartRegions.methods(objectsUsable: true, measures: colouredMeasures).first == .objects)
    }

    @Test func aCaptionedPictureIsNotText() {
        let caption = [TextBox(text: "Midsagittal section of the human brain, stock illustration", center: Point(x: 100, y: 10))]
        let marked = Rect(x: 0, y: 0, width: 200, height: 200)
        #expect(PartsTour.isMostlyText(caption, marked: marked))                        // text alone: text
        #expect(!PartsTour.isMostlyText(caption, marked: marked, colourfulShare: 0.4))  // a picture fills the box
        #expect(PartsTour.isMostlyText(caption, marked: marked, colourfulShare: 0.03))  // coloured syntax, a page
    }

    @Test func explanationsStopAtFourSentences() {
        let long = (1...9).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let limited = ExplanationCleaner.limited(long)
        #expect(limited.hasPrefix("Sentence number 1 is here."))
        #expect(limited.hasSuffix("Sentence number 4 is here."))
        #expect(ExplanationCleaner.limited("Short. Two.") == "Short. Two.")
    }
}
