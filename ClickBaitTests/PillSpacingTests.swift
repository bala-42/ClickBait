import AppKit
import ClickBaitCore
import SwiftUI
import Testing
@testable import ClickBait

/// Pills hug their text: as much room right of the words as left, above as below, one line
/// or wrapped (user's report of dead space on wrapped pills, 2026-10-25). Measured on the
/// drawn pixels: the pill's fill against its white letters.
@MainActor
struct PillSpacingTests {
    static let texts = [
        "done",
        "compressed 3 files into an archive",
        "Screen Recording is off. open Permissions… from the menu bar icon to turn it on again",
        "saved your notes to Downloads, and the summary is in the chat when you want it later on",
        "the walkthrough couldn't find History in Safari, so it stopped there for now",
    ]

    /// (left, right, top, bottom) room in points between the pill's edge and its letters.
    static func gaps(_ text: String) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        let view = NSHostingView(rootView: TinyPill(text: text, tone: .idle).padding(20).background(Color.black))
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var pill = (minX: Int.max, maxX: Int.min, minY: Int.max, maxY: Int.min)
        var ink = pill
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let isFill = c.blueComponent > 0.75 && c.redComponent < 0.25
                let isInk = c.redComponent > 0.5
                if isFill || isInk { pill = (min(pill.minX, x), max(pill.maxX, x), min(pill.minY, y), max(pill.maxY, y)) }
                if isInk { ink = (min(ink.minX, x), max(ink.maxX, x), min(ink.minY, y), max(ink.maxY, y)) }
            }
        }
        guard ink.minX != .max else { return nil }
        return (CGFloat(ink.minX - pill.minX) / scale, CGFloat(pill.maxX - ink.maxX) / scale,
                CGFloat(ink.minY - pill.minY) / scale, CGFloat(pill.maxY - ink.maxY) / scale)
    }

    @Test func pillsHugTheirText() throws {
        for text in Self.texts {
            let (left, right, top, bottom) = try #require(Self.gaps(text), "\(text) drew nothing")
            // Up to 3 pt: the letters' own side bearings ("n", "w") at 1×.
            #expect(abs(right - left) <= 3, "dead space beside: \(text)")
            #expect(abs(top - bottom) <= 1, "uneven top and bottom: \(text)")
        }
    }
}
