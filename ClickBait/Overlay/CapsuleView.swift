import AppKit
import ClickBaitCore
import Observation
import SwiftUI

@MainActor
@Observable
final class CapsulePresentation {
    /// What the card shows (it changes with every streamed word).
    var entry: BackgroundJobs.Entry {
        didSet {
            let status = Self.status(of: entry.job)
            if status != self.status { self.status = status }
            if entry.seen != seen { seen = entry.seen }
        }
    }
    var isExpanded = false
    /// What the tile shows, kept apart so streaming doesn't redraw it.
    private(set) var status: AgentDock.Status
    private(set) var seen: Bool
    let tone: CompanionTone
    let question: String

    init(entry: BackgroundJobs.Entry) {
        self.entry = entry
        status = Self.status(of: entry.job)
        seen = entry.seen
        tone = entry.job.kind == .snip ? .capture : .processing
        question = entry.job.question
    }

    private static func status(of job: BackgroundJob) -> AgentDock.Status {
        switch job.status {
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
        let look = AgentDock.look(presentation.status, opened: presentation.seen, reduceMotion: reduceMotion)
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
        return "Background ClickBait, \(state): \(presentation.question)"
    }
}

/// The card under a tile: running, done or failed.
struct CapsuleView: View {
    @Bindable var presentation: CapsulePresentation
    let onStop: (UUID) -> Void
    let onGoThere: (UUID) -> Void
    let onLater: (UUID) -> Void
    let onDismiss: (UUID) -> Void
    let onSuggestion: (UUID, String) -> Void
    let onFollowUp: (UUID, _ voice: Bool) -> Void
    let canGoThere: () -> Bool

    private var job: BackgroundJob { presentation.entry.job }
    private var tone: CompanionTone { presentation.tone }

    var body: some View {
        card
            .padding(CapsuleController.cardMargin)
            .fixedSize()
    }

    @ViewBuilder private var card: some View {
        let id = job.id
        switch job.status {
        case .working:
            // ✕ stops it: the tile goes.
            AgentRunningCard(title: job.question, liveLine: JobSummary.liveLine(from: presentation.entry.liveText),
                             tone: tone,
                             progressBar: AnyView(CapsuleProgressBar(progress: presentation.entry.progress, tone: tone.color)),
                             onStop: { onStop(id) })
        case .done(let summary):
            AgentDoneCard(title: job.question, summary: summary, suggestions: presentation.entry.offeredSuggestions,
                          tone: tone, canGoThere: canGoThere(),
                          onClose: { onDismiss(id) },
                          onSuggestion: { onSuggestion(id, $0) },
                          onFollowUpText: { onFollowUp(id, false) },
                          onFollowUpVoice: { onFollowUp(id, true) },
                          onGoThere: { onGoThere(id) },
                          onLater: { onLater(id) })
        case .failed(let reason):
            AgentFailedCard(title: job.question, reason: reason, tone: tone, onClose: { onDismiss(id) })
        case .stopped:
            EmptyView()
        }
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
                    Capsule().fill(Color.white.opacity(0.1))
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
