import Testing
@testable import ClickBaitCore

struct SpaceToyTests {
    private let limit = Point(x: 120, y: 10)

    private func run(_ toy: inout SpaceToy, seconds: Double) -> Double {
        var hardest = 0.0
        for _ in 0..<Int(seconds * 60) { hardest = max(hardest, toy.step(1.0 / 60, limit: limit)) }
        return hardest
    }

    @Test func letGoItSpringsBackPastHomeAndSettles() {
        var toy = SpaceToy()
        toy.offset = Point(x: 80, y: 0)
        toy.letGo(velocity: Point(x: 0, y: 0))
        var overshot = false
        for _ in 0..<60 {
            _ = toy.step(1.0 / 60, limit: limit)
            if toy.offset.x < -5 { overshot = true }
        }
        #expect(overshot)  // elastic: past the middle and back
        _ = run(&toy, seconds: 3)
        #expect(toy.offset == Point(x: 0, y: 0) && !toy.isMoving)
    }

    @Test func itBouncesOffTheEdgesAndStaysInside() {
        var toy = SpaceToy()
        toy.letGo(velocity: Point(x: 300, y: 900))
        let hit = run(&toy, seconds: 1)
        #expect(hit > 200)
        #expect(abs(toy.offset.x) <= limit.x + 20 && abs(toy.offset.y) <= limit.y + 20)
    }

    @Test func leftAloneItGoesHomeAndStops() {
        var toy = SpaceToy()
        toy.offset = Point(x: 80, y: 6)
        toy.letGo(velocity: Point(x: 0, y: 0))
        _ = run(&toy, seconds: 4)
        #expect(toy.offset == Point(x: 0, y: 0))
        #expect(!toy.isMoving)
    }

    @Test func letGoPastAnEdgeItComesInWithoutAJump() {
        var toy = SpaceToy()
        toy.offset = Point(x: 0, y: 28)  // pulled well past the edge
        toy.letGo(velocity: Point(x: 0, y: 0))
        let before = toy.offset.y
        _ = toy.step(1.0 / 60, limit: limit)
        #expect(before - toy.offset.y < 3)
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
