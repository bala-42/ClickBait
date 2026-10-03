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

    func show(_ question: String, at topLeft: CGPoint) {
        hide()
        let view = ConfirmCard(question: question) { [weak self] yes in self?.answer(yes) }
        let host = NSHostingView(rootView: view)
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
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.waitTime)
            guard !Task.isCancelled else { return }
            self?.answer(false)
        }
    }

    func hide() {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func answer(_ yes: Bool) {
        guard panel != nil else { return }
        hide()
        onAnswer?(yes)
    }
}

private struct ConfirmCard: View {
    let question: String
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question)
                .font(.system(size: 12.5, weight: .semibold))
                .wrapped(question, maxWidth: 260, size: 12.5)
            HStack(spacing: 6) {
                Button { answer(true) } label: {
                    Text("Do it").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(CompanionTone.action.color)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.white, in: Capsule())
                }
                Button { answer(false) } label: {
                    Text("Cancel").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.2), in: Capsule())
                }
                Text("or say “yes”").font(.system(size: 11)).opacity(0.8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .modifier(ToneFill(fill: CompanionTone.action.color.opacity(0.92), glow: CompanionTone.action.color.opacity(0.45),
                           shape: RoundedRectangle(cornerRadius: 13, style: .continuous)))
        .padding(8)
        .fixedSize()
    }
}
