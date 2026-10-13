import Foundation
import Testing
@testable import ClickBaitCore

struct AgentDockTests {
    /// A 1512×949 visible frame (below a 33 pt menu bar), y up.
    private let visible = Rect(x: 0, y: 0, width: 1512, height: 949)

    @Test func tilesStackDownFromTheTopRight() throws {
        let first = try #require(AgentDock.tile(0, in: visible))
        #expect(first == Rect(x: 1512 - 27 - 33, y: 949 - 32 - 33, width: 33, height: 33))
        let second = try #require(AgentDock.tile(1, in: visible))
        #expect(first.maxY - second.maxY == 42)  // 42 pt top to top
        #expect(second.maxX == first.maxX)
        #expect(AgentDock.tile(3, in: visible) == nil)
        #expect(AgentDock.tile(-1, in: visible) == nil)
    }

    @Test func dotSitsInTheTopRightCorner() throws {
        let tile = try #require(AgentDock.tile(0, in: visible))
        #expect(AgentDock.dotCenter(of: tile) == Point(x: tile.maxX - 4.5, y: tile.maxY - 4.5))
    }

    @Test func newestTakesTheTopAndTheOthersMoveDown() {
        #expect(AgentDock.slots(newestFirst: ["a"]) == ["a": 0])
        #expect(AgentDock.slots(newestFirst: ["b", "a"]) == ["b": 0, "a": 1])
        #expect(AgentDock.slots(newestFirst: ["d", "c", "b", "a"]) == ["d": 0, "c": 1, "b": 2])
    }

    @Test func cardHangsUnderItsTileRightAligned() throws {
        let tile = try #require(AgentDock.tile(2, in: visible))
        let card = AgentDock.card(under: tile, height: 200, in: visible)
        #expect(card.maxX == tile.maxX)
        #expect(card.width == 288)
        #expect(card.maxY == tile.minY - 8)
        #expect(card.height == 200)
    }

    @Test func cardStaysOnScreen() throws {
        let small = Rect(x: 0, y: 0, width: 260, height: 300)
        let tile = try #require(AgentDock.tile(2, in: small))
        let card = AgentDock.card(under: tile, height: 400, in: small)
        #expect(card.minX >= 8)
        #expect(card.minY >= 8)
        #expect(card.maxY <= tile.minY - 8)
    }

    @Test func spawnGrowsFliesAndDocks() {
        let cursor = Point(x: 300, y: 400), slot = Point(x: 1400, y: 900)
        let start = AgentDock.spawn(at: 0, from: cursor, to: slot)
        #expect(start.center == cursor && start.scale == 1 && start.freshScale == 0 && !start.docked)
        let grown = AgentDock.spawn(at: AgentDock.growTime, from: cursor, to: slot)
        #expect(abs(grown.scale - AgentDock.grownScale) < 1e-9)
        #expect(grown.center == cursor)
        let midway = AgentDock.spawn(at: AgentDock.growTime + AgentDock.flightTime / 2, from: cursor, to: slot)
        #expect(midway.center != cursor && midway.center != slot)
        #expect(midway.tileOpacity == 1)  // the tile is in its slot before the triangle arrives
        #expect(midway.freshScale == 1)  // a fresh companion is already listening
        #expect(midway.swell > 0)
        let end = AgentDock.spawn(at: AgentDock.growTime + AgentDock.flightTime, from: cursor, to: slot)
        #expect(end.docked)
        #expect(abs(end.center.x - slot.x) < 1e-9 && abs(end.center.y - slot.y) < 1e-9)
        #expect(abs(end.scale - AgentDock.triangleSize / 16) < 1e-9)
        #expect(abs(end.angle) < 1e-9)  // upright in its tile
        #expect(start.angle == AgentDock.restingAngle)
    }

    @Test func spawnTakesAboutTwoThirdsOfASecond() {
        // Measured in the video: grow 102.50–102.60 s, fly to 103.17–103.20 s.
        let total = AgentDock.growTime + AgentDock.flightTime
        #expect(total >= 0.6 && total <= 0.7)
        #expect(AgentDock.slide(at: 0) == 0)
        #expect(AgentDock.slide(at: AgentDock.growTime + AgentDock.flightTime * AgentDock.tileShare) == 1)
    }

    @Test func freshCompanionPopsInAsTheFlightLeaves() {
        let cursor = Point(x: 0, y: 0), slot = Point(x: 1000, y: 600)
        let leaving = AgentDock.spawn(at: AgentDock.growTime + 0.05, from: cursor, to: slot)
        #expect(leaving.freshScale > 0 && leaving.freshScale < 1)
        let popped = AgentDock.spawn(at: AgentDock.growTime + AgentDock.popTime, from: cursor, to: slot)
        #expect(popped.freshScale == 1)
    }

    @Test func statusDecidesTheLook() {
        let working = AgentDock.look(.working, opened: false, reduceMotion: false)
        #expect(working == .init(dot: .azure, spins: true, pulses: false, dimmed: false))
        let calm = AgentDock.look(.working, opened: false, reduceMotion: true)
        #expect(!calm.spins && calm.pulses)
        #expect(AgentDock.look(.done, opened: false, reduceMotion: false) == .init(dot: .shamrock, spins: false, pulses: true, dimmed: false))
        #expect(!AgentDock.look(.done, opened: true, reduceMotion: false).pulses)
        #expect(AgentDock.look(.failed, opened: false, reduceMotion: false) == .init(dot: .grey, spins: false, pulses: false, dimmed: true))
        #expect(AgentDock.look(.stopped, opened: false, reduceMotion: false).dimmed)
    }
}
