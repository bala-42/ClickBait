import Foundation

/// The notch's timer (user's ask, 2026-11-02, after Vorssaint's): a countdown set on a ruler of
/// minutes, Pomodoro (25 minutes of work, 5 of rest, a long 15 after every fourth), and a
/// stopwatch. The arithmetic only; the app runs the clock.
public enum NotchTimer {
    public enum Mode: String, CaseIterable, Sendable { case timer, pomodoro, stopwatch }

    /// The ruler runs from 1 minute to 3 hours.
    public static let minutes = 1...180

    /// A ruler label: "1", "5" … "55", then "1h00", "1h05" … (every fifth minute, and the first).
    public static func label(forMinute minute: Int) -> String? {
        guard minute == 1 || minute % 5 == 0 else { return nil }
        return minute < 60 ? "\(minute)" : "\(minute / 60)h\(String(format: "%02d", minute % 60))"
    }

    /// The readout: "15:00", "4:05", and with hours "1:02:00".
    public static func readout(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    public enum Phase: Equatable, Sendable { case work, shortBreak, longBreak }

    /// Pomodoro's phases in order: work, break, work, break, work, break, work, long break.
    public static func pomodoroPhase(after completed: Int) -> Phase {
        guard completed % 2 == 1 else { return .work }
        return completed % 8 == 7 ? .longBreak : .shortBreak
    }

    public static func length(of phase: Phase) -> TimeInterval {
        switch phase {
        case .work: 25 * 60
        case .shortBreak: 5 * 60
        case .longBreak: 15 * 60
        }
    }
}
