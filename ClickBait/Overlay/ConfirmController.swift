import AppKit
import SwiftUI

/// Asks before an action the model proposed that moves, renames, bins or quits
/// something: a small green card by the companion with Do it / Cancel. Clickable
/// without taking focus from the app in front. Answering by voice ("yes" / "cancel")
/// or Esc works too; it gives up on its own after a while.
@MainActor
final class ConfirmController {
    var onAnswer: ((Bool) -> Void)?
    private var panel: NSPanel?
    private var timeout: Task<Void, Never>?
    static let waitTime: Duration = .seconds(20)

    var isShowing: Bool { panel != nil }

    /// `answer` handles this card's answer instead of `onAnswer` (e.g. "back to Notes?").
    func show(_ question: String, at topLeft: CGPoint, confirm: String = "Do it", cancel: String = "Cancel",
              hint: String? = "or say “yes”", tone: CompanionTone = .action, answer: ((Bool) -> Void)? = nil) {
        hide()
        oneOffAnswer = answer
        let view = ConfirmCard(question: question, confirm: confirm, cancel: cancel, hint: hint, tone: tone) { [weak self] yes in self?.answer(yes) }
        present(NSHostingView(rootView: view), at: topLeft) { [weak self] in self?.answer(false) }
    }

    /// A question with a few answers, one button each (e.g. a reminder's day). `answer`
    /// gets the chosen index, or nil if it timed out. Esc and voice answers go through
    /// the coordinator, which then calls `hide()`.
    func showChoice(_ question: String, options: [String], at topLeft: CGPoint, hint: String?,
                    tone: CompanionTone = .action, answer: @escaping (Int?) -> Void) {
        hide()
        choiceAnswer = answer
        let view = ChoiceCard(question: question, options: options, hint: hint, tone: tone) { [weak self] index in
            self?.answerChoice(index)
        }
        present(NSHostingView(rootView: view), at: topLeft) { [weak self] in self?.answerChoice(nil) }
    }

    private func present(_ host: NSView, at topLeft: CGPoint, onTimeout: @escaping () -> Void) {
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
            panel.setFrame(frame, display: false)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        timeout = Task {
            try? await Task.sleep(for: Self.waitTime)
            guard !Task.isCancelled else { return }
            onTimeout()
        }
    }

    func hide() {
        choiceAnswer = nil
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private var oneOffAnswer: ((Bool) -> Void)?
    private var choiceAnswer: ((Int?) -> Void)?

    private func answerChoice(_ index: Int?) {
        guard panel != nil, let choiceAnswer else { return }
        hide()
        choiceAnswer(index)
    }

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
            Text(question)
                .font(.system(size: 12.5, weight: .semibold))
                .wrapped(question, maxWidth: 260, size: 12.5)
            HStack(spacing: 6) {
                Button { answer(true) } label: {
                    Text(confirm).font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tone.color)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.white, in: Capsule())
                }
                Button { answer(false) } label: {
                    Text(cancel).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.2), in: Capsule())
                }
                if let hint { Text(hint).font(.system(size: 11)).opacity(0.8) }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .modifier(ToneFill(fill: tone.color.opacity(0.92), glow: tone.color.opacity(0.45),
                           shape: RoundedRectangle(cornerRadius: 13, style: .continuous)))
        .padding(8)
        .fixedSize()
    }
}

/// The choice version of `ConfirmCard`: the first option is the main (white) button.
private struct ChoiceCard: View {
    let question: String
    let options: [String]
    let hint: String?
    let tone: CompanionTone
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question)
                .font(.system(size: 12.5, weight: .semibold))
                .wrapped(question, maxWidth: 260, size: 12.5)
            HStack(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button { choose(index) } label: {
                        Text(option)
                            .font(.system(size: 12, weight: index == 0 ? .bold : .semibold))
                            .foregroundStyle(index == 0 ? tone.color : .white)
                            .padding(.horizontal, 11).padding(.vertical, 4)
                            .background(index == 0 ? .white : .white.opacity(0.2), in: Capsule())
                    }
                }
                if let hint { Text(hint).font(.system(size: 11)).opacity(0.8) }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .modifier(ToneFill(fill: tone.color.opacity(0.92), glow: tone.color.opacity(0.45),
                           shape: RoundedRectangle(cornerRadius: 13, style: .continuous)))
        .padding(8)
        .fixedSize()
    }
}
