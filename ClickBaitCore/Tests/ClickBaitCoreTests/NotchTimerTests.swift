import Testing
@testable import ClickBaitCore

struct NotchTimerTests {
    @Test func rulerLabels() {
        #expect(NotchTimer.label(forMinute: 1) == "1")
        #expect(NotchTimer.label(forMinute: 15) == "15")
        #expect(NotchTimer.label(forMinute: 7) == nil)
        #expect(NotchTimer.label(forMinute: 60) == "1h00")
        #expect(NotchTimer.label(forMinute: 65) == "1h05")
    }

    @Test func readouts() {
        #expect(NotchTimer.readout(15 * 60) == "15:00")
        #expect(NotchTimer.readout(62 * 60) == "1:02:00")
        #expect(NotchTimer.readout(4.2) == "0:05")
        #expect(NotchTimer.readout(-3) == "0:00")
    }

    @Test func pomodoroCycle() {
        let phases = (0..<8).map(NotchTimer.pomodoroPhase(after:))
        #expect(phases == [.work, .shortBreak, .work, .shortBreak, .work, .shortBreak, .work, .longBreak])
        #expect(NotchTimer.length(of: .work) == 1500)
    }
}
