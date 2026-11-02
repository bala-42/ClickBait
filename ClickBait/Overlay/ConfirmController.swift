import AppKit
import ClickBaitCore
import SwiftUI

/// Asks before an action the model proposed that moves, renames, bins or quits
/// something: a small green card by the companion with Do it / Cancel. Clickable
/// without taking focus from the app in front. Answering by voice ("yes" / "cancel")
/// or Esc works too; it gives up on its own after a while.
@MainActor
final class ConfirmController {
    var onAnswer: ((Bool) -> Void)?
    private var panel: NSPanel?
    /// The notch's windows on screen (set by the app delegate): cards keep clear of them.
    static var notchFrames: () -> [CGRect] = { [] }
    static let notchGap: CGFloat = 16
    private var timeout: Task<Void, Never>?
    static let waitTime: Duration = .seconds(20)

    var isShowing: Bool { panel != nil }

    /// `answer` handles this card's answer instead of `onAnswer` (e.g. "back to Notes?").
    /// An empty `question` makes it a pill of just the two buttons. `waitTime` overrides
    /// how long it waits before giving up (as if cancelled).
    func show(_ question: String, at topLeft: CGPoint, confirm: String = "Do it", cancel: String = "Cancel",
              hint: String? = "or say “yes”", tone: CompanionTone = .action, waitTime: Duration? = nil,
              answer: ((Bool) -> Void)? = nil) {
        hide()
        oneOffAnswer = answer
        // Pills are small letters, names as they are (user's rule, 2026-11-02): "convert 1 item to MP4?".
        let view = ConfirmCard(question: Self.cased(question), confirm: Self.cased(confirm), cancel: Self.cased(cancel),
                               hint: hint.map(Self.cased), tone: tone) { [weak self] yes in self?.answer(yes) }
        present(NSHostingView(rootView: view), at: topLeft, waitTime: waitTime) { [weak self] in self?.answer(false) }
    }

    private static func cased(_ text: String) -> String { PillCase.lowered(text, names: AppLocator.pillNames) }

    enum ChoiceAnswer {
        case option(Int)
        /// Picked on the card's calendar.
        case date(Date)
        case timedOut
    }

    /// A question with a few answers, one button each (e.g. a reminder's day), and with
    /// `datePicker` a 📅 button that opens a calendar in the card for any other day.
    /// Esc and voice answers go through the coordinator, which then calls `hide()`.
    func showChoice(_ question: String, options: [String], at topLeft: CGPoint, hint: String?, datePicker: Bool = false,
                    tone: CompanionTone = .action, answer: @escaping (ChoiceAnswer) -> Void) {
        hide()
        choiceAnswer = answer
        let view = ChoiceCard(
            question: Self.cased(question), options: options.map(Self.cased), hint: hint.map(Self.cased), datePicker: datePicker, tone: tone,
            choose: { [weak self] index in self?.answerChoice(.option(index)) },
            chooseDate: { [weak self] date in self?.answerChoice(.date(date)) },
            calendarShown: { [weak self] in self?.restartTimeout(after: Self.browsingTime) },
            sizeChanged: { [weak self] size in self?.fit(size) }
        )
        present(NSHostingView(rootView: view), at: topLeft) { [weak self] in self?.answerChoice(.timedOut) }
    }

    /// Longer than `waitTime`: someone looking through the calendar is still answering.
    static let browsingTime: Duration = .seconds(60)
    private var onTimeout: (() -> Void)?

    private func restartTimeout(after delay: Duration) {
        timeout?.cancel()
        guard let onTimeout else { return }
        timeout = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            onTimeout()
        }
    }

    /// The card grew (calendar opened) or shrank: same top edge, still on screen.
    private func fit(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let rounded = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard rounded != panel.frame.size else { return }
        var frame = CGRect(x: panel.frame.minX, y: panel.frame.maxY - rounded.height, width: rounded.width, height: rounded.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
    }

    private func present(_ host: NSView, at topLeft: CGPoint, waitTime: Duration? = nil, onTimeout: @escaping () -> Void) {
        let size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.setFrameTopLeftPoint(topLeft)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(topLeft) }) {
            var frame = panel.frame
            frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
            // Never on or touching the notch: down the screen, below it with a gap (a card by the
            // cursor while it was on the shelf hid under the notch; user's report, 2026-11-02).
            for notch in Self.notchFrames() where notch.insetBy(dx: -Self.notchGap, dy: -Self.notchGap).intersects(frame) {
                frame.origin.y = max(notch.minY - Self.notchGap - frame.height, screen.visibleFrame.minY)
            }
            panel.setFrame(frame, display: false)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.onTimeout = onTimeout
        restartTimeout(after: waitTime ?? Self.waitTime)
    }

    func hide() {
        choiceAnswer = nil
        onTimeout = nil
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private var oneOffAnswer: ((Bool) -> Void)?
    private var choiceAnswer: ((ChoiceAnswer) -> Void)?

    /// Esc on a card nobody else stopped: "no" (a choice card: as if it timed out), so
    /// whoever asked hears back.
    func cancel() {
        if choiceAnswer != nil { answerChoice(.timedOut) } else { answer(false) }
    }

    private func answerChoice(_ answer: ChoiceAnswer) {
        guard panel != nil, let choiceAnswer else { return }
        hide()
        choiceAnswer(answer)
    }

    #if DEBUG
    /// Presses the showing card's button from a live test (`org.clickbait.debug.card`).
    func debugAnswer(_ yes: Bool) { answer(yes) }
    #endif

    private func answer(_ yes: Bool) {
        guard panel != nil else { return }
        hide()
        if let oneOff = oneOffAnswer {
            oneOffAnswer = nil
            oneOff(yes)
        } else {
            onAnswer?(yes)
        }
    }
}

private struct ConfirmCard: View {
    let question: String
    let confirm: String
    let cancel: String
    let hint: String?
    let tone: CompanionTone
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.isEmpty {
                Text(question)
                    .font(.system(size: 12.5, weight: .semibold))
                    .wrapped(question, maxWidth: 260, size: 12.5)
            }
            HStack(spacing: 6) {
                Button { answer(true) } label: {
                    Text(confirm).font(.system(size: 12, weight: .bold)).oneLine()
                        .foregroundStyle(tone.color)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.white, in: Capsule())
                }
                Button { answer(false) } label: {
                    Text(cancel).font(.system(size: 12, weight: .semibold)).oneLine()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.2), in: Capsule())
                }
                if let hint { Text(hint).font(.system(size: 11)).oneLine().opacity(0.8) }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .modifier(ToneFill(fill: tone.color.opacity(0.92), glow: tone.color.opacity(Glow.opacity),
                           shape: RoundedRectangle(cornerRadius: 13, style: .continuous)))
        .padding(8)
        .fixedSize()
    }
}

/// The choice version of `ConfirmCard`: the first option is the main (white) button.
/// With `datePicker`, a 📅 button opens a calendar below for any other day.
private struct ChoiceCard: View {
    let question: String
    let options: [String]
    let hint: String?
    let datePicker: Bool
    let tone: CompanionTone
    let choose: (Int) -> Void
    let chooseDate: (Date) -> Void
    let calendarShown: () -> Void
    let sizeChanged: (CGSize) -> Void

    /// Today up to a year ahead.
    private static var pickableDays: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: .now)
        return today...(Calendar.current.date(byAdding: .year, value: 1, to: today) ?? today)
    }

    @State private var showsCalendar = false
    @State private var picked = Calendar.current.startOfDay(for: .now)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question)
                .font(.system(size: 12.5, weight: .semibold))
                .wrapped(question, maxWidth: 260, size: 12.5)
            HStack(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button { choose(index) } label: {
                        pill(option, primary: index == 0)
                    }
                }
                if datePicker {
                    Button {
                        showsCalendar.toggle()
                        if showsCalendar { calendarShown() }
                    } label: {
                        Image(systemName: showsCalendar ? "calendar.badge.minus" : "calendar")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.white.opacity(showsCalendar ? 0.35 : 0.2), in: Capsule())
                    }
                    .help("Pick a day")
                    .accessibilityLabel("Pick a day on a calendar")
                }
                if let hint, !showsCalendar { Text(hint).font(.system(size: 11)).oneLine().opacity(0.8) }
            }
            if showsCalendar {
                VStack(alignment: .trailing, spacing: 6) {
                    DatePicker("Day", selection: $picked, in: Self.pickableDays, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(6)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .environment(\.colorScheme, .light)
                    Button { chooseDate(picked) } label: {
                        pill("Add for \(picked.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))", primary: true)
                    }
                }
                .transition(.opacity)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .modifier(ToneFill(fill: tone.color.opacity(0.92), glow: tone.color.opacity(Glow.opacity),
                           shape: RoundedRectangle(cornerRadius: 13, style: .continuous)))
        .padding(8)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeChanged($0) }
    }

    private func pill(_ text: String, primary: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: primary ? .bold : .semibold))
            .oneLine()
            .inkCentred(text, weight: primary ? .bold : .semibold)
            .foregroundStyle(primary ? tone.color : .white)
            .padding(.horizontal, 11).padding(.vertical, 4)
            .background(primary ? .white : .white.opacity(0.2), in: Capsule())
    }
}

private extension Text {
    /// Buttons and hints never wrap ("Tomorrow" broke onto two lines when the question
    /// above set the card's width): the card grows to fit them instead.
    func oneLine() -> some View {
        lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}
