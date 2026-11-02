import ClickBaitCore
import SwiftUI

/// The Timer page (user's reference, Vorssaint's timer; colour: the teleprompter's cream): Timer
/// · Pomodoro · Stopwatch, Start, the ruler of minutes and the readout.
struct NotchTimerView: View {
    @Bindable var clock = NotchTimerClock.shared
    /// False only to draw it to an image (AppKit input can't be drawn there).
    var interactive = true
    private let cream = MoodyLook.cream

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                ForEach(NotchTimer.Mode.allCases, id: \.self) { mode in
                    Button { clock.choose(mode) } label: {
                        VStack(spacing: 4) {
                            Text(mode.rawValue.capitalized)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(clock.mode == mode ? NotchPalette.text : NotchPalette.tertiary)
                            Capsule().fill(clock.mode == mode ? cream : .clear).frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if clock.running || clock.leftWhenPaused != nil || clock.elapsedBefore > 0 {
                    Button("Reset") { clock.reset() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NotchPalette.secondary)
                }
                if clock.ringing {
                    Button { clock.onStopAlarm?() } label: {
                        Text("Stop alarm")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(Color(hex: 0xE0115F), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                Button { clock.startOrPause() } label: {
                    Text(clock.running ? "Pause" : clock.leftWhenPaused != nil || clock.elapsedBefore > 0 ? "Resume" : "Start")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(cream)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(cream.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if clock.mode == .stopwatch {
                // Centred, to the millisecond, redrawn every frame while running (user's ask, 2026-11-02).
                TimelineView(.animation(paused: !clock.running)) { context in
                    Text(NotchTimer.preciseReadout(clock.shown(at: context.date)))
                        .font(.system(size: 36, weight: .light).monospacedDigit())
                        .foregroundStyle(cream)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            HStack(alignment: .bottom, spacing: 16) {
                Group {
                    switch clock.mode {
                    case .timer: MinuteRuler(minutes: $clock.minutes, cream: cream, interactive: interactive).disabled(clock.running || clock.leftWhenPaused != nil)
                    case .pomodoro: PomodoroDots(done: clock.pomodorosDone, phase: clock.phase, cream: cream)
                    case .stopwatch: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
                TimelineView(.periodic(from: .now, by: clock.running ? 0.25 : 60)) { context in
                    Text(NotchTimer.readout(clock.shown(at: context.date)))
                        .font(.system(size: 30, weight: .light).monospacedDigit())
                        .foregroundStyle(cream)
                        .contentTransition(.numericText())
                }
                .frame(minWidth: 96, alignment: .trailing)
            }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Minutes on a ruler, dragged sideways; the one at the marker is the countdown. Ticks up to it
/// are full cream, the rest faint; a label every fifth minute.
private struct MinuteRuler: View {
    @Binding var minutes: Int
    let cream: Color
    var interactive = true
    private let pitch: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            let middle = geometry.size.width / 2
            ZStack(alignment: .topLeading) {
                ForEach(NotchTimer.minutes, id: \.self) { minute in
                    let x = middle + CGFloat(minute - minutes) * pitch
                    if x > -pitch, x < geometry.size.width + pitch {
                        let near = abs(x - middle) / middle
                        VStack(spacing: 4) {
                            Text(NotchTimer.label(forMinute: minute) ?? " ")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(cream.opacity(minute <= minutes ? 0.9 : 0.35))
                                .fixedSize()
                            Capsule()
                                .fill(cream.opacity(minute <= minutes ? 0.9 : 0.22))
                                .frame(width: 2.5, height: 26)
                        }
                        .opacity(1 - Double(near) * 0.55)
                        .position(x: x, y: 24)
                    }
                }
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(cream)
                    .position(x: middle, y: 51)
            }
            .overlay(interactive ? RulerInput(pitch: pitch) { step in
                minutes = min(max(minutes + step, NotchTimer.minutes.lowerBound), NotchTimer.minutes.upperBound)
            } : nil)
        }
        .frame(height: 56)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Timer length")
        .accessibilityValue("\(minutes) minutes")
        .accessibilityAdjustableAction { direction in
            minutes = min(max(minutes + (direction == .increment ? 1 : -1), NotchTimer.minutes.lowerBound), NotchTimer.minutes.upperBound)
        }
    }
}

/// Pomodoro's four work sessions as dots (done filled), and what's running or next.
private struct PomodoroDots: View {
    let done: Int
    let phase: NotchTimer.Phase
    let cream: Color

    /// Work sessions done in this set of four (the long break ends a set).
    private var workDone: Int { min(4, (done % 8 + 1) / 2) }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(cream.opacity(index < workDone ? 0.9 : 0.18))
                    .frame(width: 10, height: 10)
            }
            Text(phase == .work ? "work · 25 min" : phase == .shortBreak ? "break · 5 min" : "long break · 15 min")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotchPalette.secondary)
            Spacer()
        }
        .frame(height: 52)
    }
}

/// The ruler's input: dragged sideways (left adds minutes) or scrolled, one minute per `pitch`.
private struct RulerInput: NSViewRepresentable {
    let pitch: CGFloat
    let onStep: (Int) -> Void
    func makeNSView(context: Context) -> NSView { InputView(pitch: pitch, onStep: onStep) }
    func updateNSView(_ view: NSView, context: Context) { (view as? InputView)?.onStep = onStep }

    final class InputView: NSView {
        let pitch: CGFloat
        var onStep: (Int) -> Void
        private var pending: CGFloat = 0
        init(pitch: CGFloat, onStep: @escaping (Int) -> Void) { (self.pitch, self.onStep) = (pitch, onStep); super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDragged(with event: NSEvent) { add(-event.deltaX) }
        override func scrollWheel(with event: NSEvent) {
            add(event.scrollingDeltaX != 0 ? -event.scrollingDeltaX : -event.scrollingDeltaY)
        }
        private func add(_ points: CGFloat) {
            pending += points
            while abs(pending) >= pitch {
                onStep(pending > 0 ? 1 : -1)
                pending -= pending > 0 ? pitch : -pitch
            }
        }
    }
}
