import Testing
@testable import ClickBaitCore

struct WindowSwitchTests {
    @Test func picksAndMoves() {
        let windows = [
            WindowSwitch.Window(id: 1, pid: 10, layer: 0, width: 800, height: 600, title: "Notes"),
            WindowSwitch.Window(id: 2, pid: 99, layer: 0, width: 800, height: 600, title: "ClickBait"),  // own
            WindowSwitch.Window(id: 3, pid: 11, layer: 25, width: 800, height: 30, title: "menu"),  // not a window layer
            WindowSwitch.Window(id: 4, pid: 12, layer: 0, width: 40, height: 40, title: "dot"),  // tiny
            WindowSwitch.Window(id: 5, pid: 13, layer: 0, width: 1200, height: 800, title: "Safari"),
        ]
        #expect(WindowSwitch.eligible(windows, own: 99).map(\.id) == [1, 5])
        #expect(WindowSwitch.first(count: 3, backwards: false) == 1 && WindowSwitch.first(count: 3, backwards: true) == 2)
        #expect(WindowSwitch.first(count: 1, backwards: false) == 0)
        #expect(WindowSwitch.step(2, count: 3, backwards: false) == 0 && WindowSwitch.step(0, count: 3, backwards: true) == 2)
    }
}
