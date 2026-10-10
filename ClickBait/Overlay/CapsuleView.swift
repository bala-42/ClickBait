import AppKit
import ClickBaitCore
import Observation
import SwiftUI

@MainActor
@Observable
final class CapsulePresentation {
    var entry: BackgroundJobs.Entry
    var isExpanded = false
    var isMinimized = false

    init(entry: BackgroundJobs.Entry) { self.entry = entry }
}

struct CapsuleView: View {
    @Bindable var presentation: CapsulePresentation
    let onStop: (UUID) -> Void
    let onGoThere: (UUID) -> Void
    let onLater: (UUID) -> Void
    let onDismiss: (UUID) -> Void
    let canGoThere: () -> Bool
    let onLayoutChange: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var job: BackgroundJob { presentation.entry.job }
    private var tone: CompanionTone { job.kind == .snip ? .capture : .processing }
    private var finished: Bool {
        if case .working = job.status { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: CapsuleLayout.cardGap) {
            if !presentation.isMinimized {
                Button { presentation.isExpanded.toggle(); onLayoutChange() } label: {
                    HStack(spacing: 1) {
                        CompanionTriangle(tone: tone, pulsing: !finished && !reduceMotion,
                                          spinning: !finished && !reduceMotion)
                            .scaleEffect(0.72)
                            .frame(width: 30, height: 24)
                        if finished {
                            Circle().fill(tone.color).frame(width: 6, height: 6)
                                .offset(x: 1, y: -8)
                        }
                    }
                    .frame(width: CapsuleLayout.capsuleWidth, height: CapsuleLayout.capsuleHeight)
                    .background {
                        Capsule().fill(Color.black.opacity(0.42)).background(.ultraThinMaterial, in: Capsule())
                    }
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
                    .shadow(color: tone.color.opacity(Glow.opacity), radius: Glow.radius)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(presentation.isExpanded ? "Collapse background task" : "Expand background task")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if presentation.isExpanded {
                card
                    .frame(width: CapsuleLayout.cardWidth, alignment: .leading)
                    .padding(11)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.13), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fixedSize()
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: presentation.isExpanded)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: presentation.isMinimized)
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
