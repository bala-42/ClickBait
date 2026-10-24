import Testing
@testable import ClickBaitCore

struct SpaceToyTests {
    private let limit = Point(x: 120, y: 10)

    private func run(_ toy: inout SpaceToy, seconds: Double) -> Double {
        var hardest = 0.0
        for _ in 0..<Int(seconds * 60) { hardest = max(hardest, toy.step(1.0 / 60, limit: limit)) }
        return hardest
    }

    @Test func aFlickCoastsAndSlows() {
        var toy = SpaceToy()
        toy.letGo(velocity: Point(x: 100, y: 0))
        _ = run(&toy, seconds: 0.5)
        #expect(toy.offset.x > 30 && toy.offset.x < 50)
        #expect(toy.speed < 100)
    }

    @Test func itBouncesOffTheEdgesAndStaysInside() {
        var toy = SpaceToy()
        toy.letGo(velocity: Point(x: 900, y: 300))
        let hit = run(&toy, seconds: 1)
        #expect(hit > 200)
        #expect(abs(toy.offset.x) <= limit.x && abs(toy.offset.y) <= limit.y)
    }

    @Test func leftAloneItGoesHomeAndStops() {
        var toy = SpaceToy()
        toy.offset = Point(x: 80, y: 6)
        toy.letGo(velocity: Point(x: 0, y: 0))
        _ = run(&toy, seconds: 6)
        #expect(toy.offset == Point(x: 0, y: 0))
        #expect(!toy.isMoving)
    }

    @Test func aWildFlickIsCapped() {
        var toy = SpaceToy()
        toy.letGo(velocity: Point(x: 30_000, y: 0))
        #expect(toy.speed <= SpaceToy.topSpeed + 0.001)
    }

    @Test func heldItDoesntMoveByItself() {
        var toy = SpaceToy()
        toy.held = true
        toy.velocity = Point(x: 500, y: 0)
        #expect(toy.step(0.1, limit: limit) == 0)
        #expect(toy.offset == Point(x: 0, y: 0))
    }
}
