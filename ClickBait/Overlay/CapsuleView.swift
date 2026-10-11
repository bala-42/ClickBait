import AppKit
import ClickBaitCore
import Observation
import SwiftUI

@MainActor
@Observable
final class CapsulePresentation {
    var entry: BackgroundJobs.Entry
    var isExpanded = false

    init(entry: BackgroundJobs.Entry) { self.entry = entry }

    var tone: CompanionTone { entry.job.kind == .snip ? .capture : .processing }

    var status: AgentDock.Status {
        switch entry.job.status {
        case .working: .working
        case .done: .done
        case .failed: .failed
        case .stopped: .stopped
        }
    }
}

/// A job's tile in the dock (`AgentTile`): spins while working, pulses when done until
/// its card is opened, dimmed when it failed. A click opens or folds its card.
struct DockTileView: View {
    @Bindable var presentation: CapsulePresentation
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beatStart = Date()

    var body: some View {
        let look = AgentDock.look(presentation.status, opened: presentation.entry.seen, reduceMotion: reduceMotion)
        Button(action: onToggle) {
            AgentTile(tone: presentation.tone, look: look, spinning: presentation.status == .working)
                .contentShape(RoundedRectangle(cornerRadius: AgentDock.tileCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        // The pulse: only an extra cached glow fades, paused unless it pulses (the spin is
        // the triangle's own cached drawing).
        .background {
            if look.pulses {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    AgentTile.glow(presentation.tone).opacity(0.4 * beat(at: context.date))
                }
            }
        }
        .padding(CapsuleController.tileMargin)
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: look.pulses) { _, pulses in if pulses { beatStart = .now } }
    }

    /// 0…1…0: a 1.4 s beat when done; with Reduce Motion a slow 2.8 s one while working.
    private func beat(at date: Date) -> Double {
        let period = presentation.status == .working ? 2.8 : 1.4
        let phase = date.timeIntervalSince(beatStart).truncatingRemainder(dividingBy: period) / period
        return (1 - cos(phase * 2 * .pi)) / 2
    }

    private var accessibilityLabel: String {
        let state: String
        switch presentation.status {
        case .working: state = "working"
        case .done: state = "done"
        case .failed: state = "failed"
        case .stopped: state = "stopped"
        }
        return "Background ClickBait, \(state): \(presentation.entry.job.question)"
    }
}

/// The card under a tile.
struct CapsuleView: View {
    @Bindable var presentation: CapsulePresentation
    let onStop: (UUID) -> Void
    let onGoThere: (UUID) -> Void
    let onLater: (UUID) -> Void
    let onDismiss: (UUID) -> Void
    let canGoThere: () -> Bool

    private var job: BackgroundJob { presentation.entry.job }
    private var tone: CompanionTone { presentation.tone }

    var body: some View {
        card
            .frame(width: AgentDock.cardWidth - 22, alignment: .leading)
            .padding(11)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AgentDock.cardCorner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AgentDock.cardCorner).strokeBorder(.white.opacity(0.13), lineWidth: 0.7))
            .padding(CapsuleController.cardMargin)
            .fixedSize()
    }

    @ViewBuilder private var card: some View {
        switch job.status {
        case .working:
            VStack(alignment: .leading, spacing: 8) {
                Text(job.question).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("working on it…").font(.system(size: 11)).foregroundStyle(.secondary)
                CapsuleProgressBar(progress: presentation.entry.progress, tone: tone.color)
                HStack { Spacer(); action("stop", role: .destructive) { onStop(job.id) } }
            }
        case .done(let summary):
            VStack(alignment: .leading, spacing: 10) {
                Text(summary).font(.system(size: 12, weight: .medium)).lineLimit(3)
                HStack(spacing: 8) {
                    action("go there!") { onGoThere(job.id) }
                        .disabled(!canGoThere())
                        .help(canGoThere() ? "" : "Finish the current question first")
                    action("later, pls") { onLater(job.id) }
                }
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn't answer: \(reason)").font(.system(size: 12, weight: .medium)).lineLimit(3)
                HStack { Spacer(); action("ok") { onDismiss(job.id) } }
            }
        case .stopped:
            EmptyView()
        }
    }

    private func action(_ title: String, role: ButtonRole? = nil, perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            Text(title).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(tone.color.opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

private struct CapsuleProgressBar: View {
    let progress: JobProgress
    let tone: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || isCounted)) { context in
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tone.opacity(0.18))
                    switch progress {
                    case .counted(let done, let total):
                        Capsule().fill(tone).frame(width: geometry.size.width * fraction(done, total))
                    case .uncounted:
                        Capsule().fill(tone)
                            .frame(width: reduceMotion ? geometry.size.width / 2 : geometry.size.width / 3)
                            .offset(x: reduceMotion ? geometry.size.width / 4 : sweepOffset(geometry.size.width, at: context.date))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 3)
        .accessibilityLabel("Task progress")
    }

    private func fraction(_ done: Int, _ total: Int) -> CGFloat {
        guard total > 0 else { return 0 }
        return min(max(CGFloat(done) / CGFloat(total), 0), 1)
    }

    private var isCounted: Bool {
        if case .counted = progress { return true }
        return false
    }

    private func sweepOffset(_ width: CGFloat, at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
        return CGFloat(phase) * (width + width / 3) - width / 3
    }
}
