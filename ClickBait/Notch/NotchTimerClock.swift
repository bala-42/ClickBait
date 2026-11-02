import ClickBaitCore
import Foundation
import Observation

/// The timer bubble's clock (user's ask, 2026-11-02, after Vorssaint's): a countdown set on the
/// ruler, Pomodoro, or a stopwatch. Runs while the notch is closed; says so when it ends.
@MainActor @Observable
final class NotchTimerClock {
    static let shared = NotchTimerClock()

    var mode: NotchTimer.Mode = .timer
    /// The ruler's minute (the countdown's length).
    var minutes = 15
    private(set) var running = false
    /// When a running countdown ends; nil for the stopwatch.
    private(set) var endsAt: Date?
    /// A countdown's time left while paused.
    private(set) var leftWhenPaused: TimeInterval?
    /// The stopwatch: when it started (running) and what it had before.
    private(set) var startedAt: Date?
    private(set) var elapsedBefore: TimeInterval = 0
    /// Pomodoro: phases finished so far, and the one running or next.
    private(set) var pomodorosDone = 0
    var phase: NotchTimer.Phase { NotchTimer.pomodoroPhase(after: pomodorosDone) }

    /// Said when a countdown or a Pomodoro phase ends ("timer's done ✓", "time for a break").
    @ObservationIgnored var onFinish: ((String) -> Void)?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    private init() {}

    /// What the readout shows at `now`.
    func shown(at now: Date) -> TimeInterval {
        switch mode {
        case .stopwatch:
            return elapsedBefore + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
        case .timer, .pomodoro:
            if let endsAt { return endsAt.timeIntervalSince(now) }
            if let leftWhenPaused { return leftWhenPaused }
            return mode == .timer ? TimeInterval(minutes * 60) : NotchTimer.length(of: phase)
        }
    }

    func startOrPause() {
        running ? pause() : start()
    }

    func start() {
        let now = Date()
        switch mode {
        case .stopwatch: startedAt = now
        case .timer, .pomodoro: endsAt = now.addingTimeInterval(shown(at: now))
        }
        leftWhenPaused = nil
        running = true
        tick()
    }

    func pause() {
        let now = Date()
        switch mode {
        case .stopwatch:
            elapsedBefore = shown(at: now)
            startedAt = nil
        case .timer, .pomodoro:
            leftWhenPaused = max(0, shown(at: now))
            endsAt = nil
        }
        running = false
        ticker?.cancel()
    }

    /// Back to the start: the ruler's length, a fresh Pomodoro, the stopwatch at zero.
    func reset() {
        ticker?.cancel()
        (running, endsAt, leftWhenPaused, startedAt, elapsedBefore) = (false, nil, nil, nil, 0)
        pomodorosDone = 0
    }

    /// Changing mode or length while stopped starts that one afresh.
    func choose(_ mode: NotchTimer.Mode) {
        guard mode != self.mode else { return }
        reset()
        self.mode = mode
    }

    private func tick() {
        ticker?.cancel()
        guard mode != .stopwatch else { return }
        ticker = Task { @MainActor [weak self] in
            while let self, self.running, !Task.isCancelled {
                if let endsAt = self.endsAt, endsAt <= Date() { self.finished(); return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func finished() {
        running = false
        endsAt = nil
        leftWhenPaused = nil
        if mode == .pomodoro {
            let was = phase
            pomodorosDone += 1
            onFinish?(was == .work ? (phase == .longBreak ? "time for a long break ✓" : "time for a break ✓") : "back to work")
        } else {
            onFinish?("timer's done ✓")
        }
    }
}
