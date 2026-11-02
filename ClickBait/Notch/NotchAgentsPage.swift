import ClickBaitCore
import SwiftUI

/// The AI Agents page (user's references: Vorssaint's AI page): Claude and Codex limits with
/// their resets, spending, what's working now, the trend, models, projects, thirteen weeks of
/// activity and Codex's banked resets (shown only). Claude in Claude's orange, Codex in Codex's
/// blue (user's rule, 2026-11-02): the tools' own colours on their own sections.
struct NotchAgentsPage: View {
    @Bindable var service = AgentUsageService.shared
    @State private var period: AgentSummary.Period = .today
    static let claudeColor = Color(hex: 0xD97757)
    static let codexColor = Color(hex: 0x7B8CF6)
    /// The Activity square under the pointer or clicked: its day shows in place of the busiest.
    @State private var pickedDay: Int?

    var body: some View {
        // Capped at the page's old height: it measures to its content, but a long list scrolls.
        ScrollView(.vertical, showsIndicators: true) { cards }
            .frame(maxHeight: GalleryPage.agents.size.height - NotchController.Model.chrome - 32)
        .scrollIndicators(.automatic)
        .task {
            while !Task.isCancelled {
                service.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Every card, top to bottom (without its scroll view, to draw it to an image too).
    var cards: some View {
        let summary = AgentSummary.of(service.records, period: period, prices: service.prices)
        return VStack(spacing: 8) {
                LiveCard(color: Self.claudeColor)
                HStack(spacing: 8) {
                    LimitsCard(name: "Claude", symbol: "sparkle", color: Self.claudeColor, limits: service.claudeLimits,
                               empty: service.loading ? "reading…" : "Claude Code isn't signed in")
                    LimitsCard(name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", color: Self.codexColor, limits: service.codexLimits,
                               empty: service.codexLimits?.plan.map { "no limits on the \($0) plan" } ?? (service.loading ? "reading…" : "Codex not found"))
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    spending(summary)
                    now
                }
                .fixedSize(horizontal: false, vertical: true)
                trend(summary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ranked("Models", "cpu", summary.models)
                    ranked("Projects", "folder", summary.projects)
                }
                .fixedSize(horizontal: false, vertical: true)
                activity.fixedSize(horizontal: false, vertical: true)
                resets.fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 8)
    }

    private func spending(_ summary: AgentSummary) -> some View {
        Card {
            HStack {
                Label("Spending", systemImage: "dollarsign.circle").cardTitle()
                Spacer()
                Menu(period.rawValue.capitalized) {
                    ForEach(AgentSummary.Period.allCases, id: \.self) { choice in
                        Button(choice.rawValue.capitalized) { period = choice }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.cost, format: .currency(code: "USD")).font(.system(size: 26, weight: .medium).monospacedDigit())
                Text("API value").font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary)
            }
            SplitBar(parts: [(summary.costByTool[.claude] ?? 0, Self.claudeColor), (summary.costByTool[.codex] ?? 0, Self.codexColor)])
            Text("\(Self.compact(summary.tokens)) tokens · \(Int((summary.cacheShare * 100).rounded()))% from cache")
                .font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary)
        }
    }

    private var now: some View {
        Card {
            Label("Now", systemImage: "waveform.path.ecg").cardTitle()
            ForEach([(AgentNotice.Tool.claude, "Claude", "sparkle", Self.claudeColor), (.codex, "Codex", "chevron.left.forwardslash.chevron.right", Self.codexColor)], id: \.1) { tool, name, symbol, color in
                HStack {
                    Image(systemName: symbol).foregroundStyle(color).frame(width: 14)
                    Text(name)
                    Spacer()
                    Text(Self.when(service.lastUse(of: tool))).foregroundStyle(NotchPalette.tertiary)
                }
                .font(.system(size: 12))
            }
            Spacer(minLength: 0)
        }
    }

    private func trend(_ summary: AgentSummary) -> some View {
        Card {
            HStack {
                Label("Trend", systemImage: "chart.bar").cardTitle()
                Spacer()
                Text("\(period.rawValue.capitalized) · \(summary.cost.formatted(.currency(code: "USD")))")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary)
            }
            let peak = max(summary.trend.map { $0.values.reduce(0, +) }.max() ?? 0, 0.01)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(summary.trend.indices, id: \.self) { index in
                    let claude = summary.trend[index][.claude] ?? 0, codex = summary.trend[index][.codex] ?? 0
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Self.codexColor).frame(height: 56 * codex / peak)
                        Rectangle().fill(Self.claudeColor).frame(height: 56 * claude / peak)
                        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
            .frame(height: 58)
            HStack {
                Text(period == .today ? "12 AM" : "\(summary.trend.count) days ago")
                Spacer()
                Text(period == .today ? "11 PM" : "today")
            }
            .font(.system(size: 9)).foregroundStyle(NotchPalette.tertiary)
        }
    }

    private func ranked(_ title: String, _ symbol: String, _ rows: [(name: String, cost: Double)]) -> some View {
        Card {
            Label(title, systemImage: symbol).cardTitle()
            let top = max(rows.first?.cost ?? 0, 0.01)
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 8) {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Capsule().fill(NotchPalette.text.opacity(0.85)).frame(width: max(4, 44 * row.cost / top), height: 3)
                    Text(row.cost, format: .currency(code: "USD")).monospacedDigit().foregroundStyle(NotchPalette.tertiary).frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 11))
            }
            if rows.isEmpty { Text("nothing yet").font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary) }
            Spacer(minLength: 0)
        }
    }

    private var activity: some View {
        let days = AgentActivity.of(service.records, prices: service.prices)
        let peak = max(days.days.max() ?? 0, 0.01)
        return Card {
            HStack {
                Label("Activity", systemImage: "square.grid.3x3.fill").cardTitle()
                Spacer()
                if days.streak > 0 { Text("🔥 \(days.streak)").font(.system(size: 11)).foregroundStyle(NotchPalette.secondary) }
            }
            HStack(alignment: .top, spacing: 16) {
                HStack(spacing: 4) {
                    ForEach(0..<13, id: \.self) { week in
                        VStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { day in
                                let index = week * 7 + day
                                let cost = days.days[index]
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(cost > 0 ? NotchPalette.text.opacity(0.25 + 0.75 * cost / peak) : Color.white.opacity(0.07))
                                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(NotchPalette.text, lineWidth: pickedDay == index ? 1 : 0))
                                    .frame(width: 8, height: 8)
                                    .contentShape(Rectangle())
                                    .onHover { inside in if inside { pickedDay = index } else if pickedDay == index { pickedDay = nil } }
                                    .onTapGesture { pickedDay = pickedDay == index ? nil : index }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(days.total, format: .currency(code: "USD").precision(.fractionLength(0))).font(.system(size: 18, weight: .medium).monospacedDigit())
                    Text("13 weeks").font(.system(size: 10)).foregroundStyle(NotchPalette.tertiary)
                    Spacer(minLength: 4)
                    row("Active days", "\(days.activeDays)")
                    // A picked square: its day, date and cost; else the busiest day (as Vorssaint's).
                    if let picked = pickedDay {
                        let date = Calendar.current.date(byAdding: .day, value: picked - 90, to: Calendar.current.startOfDay(for: Date())) ?? Date()
                        row(date.formatted(.dateTime.weekday(.wide)), "\(date.formatted(.dateTime.month(.abbreviated).day())) · \(days.days[picked].formatted(.currency(code: "USD")))")
                    } else {
                        row("Busiest day", days.busiest.map { "\($0.date.formatted(.dateTime.month(.abbreviated).day())) · \($0.cost.formatted(.currency(code: "USD")))" } ?? "–")
                    }
                }
            }
        }
    }

    private var resets: some View {
        Card {
            HStack {
                // Codex's resets: its logo in Codex blue.
                Label { Text("Resets") } icon: { Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(Self.codexColor) }
                    .cardTitle()
                Spacer()
                if let count = service.codexResets?.count, count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 0)
                        .background(Self.codexColor.opacity(0.2), in: Capsule()).foregroundStyle(Self.codexColor)
                }
            }
            Group {
                if let resets = service.codexResets, resets.count > 0 {
                    Text(resets.nextExpiry.map { "Next expires \($0.formatted(.relative(presentation: .named)))" } ?? "\(resets.count) banked")
                } else {
                    Text(service.codexLimits?.plan.map { "No banked resets on the \($0) plan" } ?? "No banked resets")
                }
            }
            .font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(NotchPalette.tertiary); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 11))
    }

    static func compact(_ tokens: Int) -> String {
        tokens >= 1_000_000_000 ? String(format: "%.1fB", Double(tokens) / 1e9)
            : tokens >= 1_000_000 ? String(format: "%.1fM", Double(tokens) / 1e6)
            : tokens >= 1_000 ? String(format: "%.0fK", Double(tokens) / 1e3) : "\(tokens)"
    }

    /// "working" within two minutes, else how long ago.
    static func when(_ date: Date?) -> String {
        guard let date else { return "–" }
        if Date().timeIntervalSince(date) < 120 { return "working" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// One tool's limits: its plan, the session and the week, each with how much is used, a tick for
/// how far through its window it is, and when it starts afresh.
private struct LimitsCard: View {
    let name: String
    let symbol: String
    let color: Color
    let limits: AgentLimits?
    let empty: String

    var body: some View {
        Card {
            HStack {
                // The logo in its own colour, Claude orange or Codex blue (user's ask, 2026-11-02).
                Label { Text(name).foregroundStyle(NotchPalette.text) } icon: { Image(systemName: symbol).foregroundStyle(color) }
                    .cardTitle()
                Spacer()
                if let plan = limits?.plan {
                    Text(plan).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 0)
                        .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
                }
            }
            if limits?.session == nil, limits?.week == nil {
                Text(empty).font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary)
                Spacer(minLength: 0)
            } else {
                if let session = limits?.session { window("Session", session, length: 5 * 3600) }
                if let week = limits?.week { window("Week", week, length: 7 * 86_400) }
            }
        }
    }

    private func window(_ title: String, _ window: AgentLimits.Window, length: TimeInterval) -> some View {
        let elapsed = window.resets.map { min(1, max(0, 1 - $0.timeIntervalSinceNow / length)) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                if let resets = window.resets {
                    Text("↻ \(Self.left(resets))").foregroundStyle(NotchPalette.tertiary)
                }
                Spacer()
                Text("\(Int(window.percent.rounded()))%").monospacedDigit().fontWeight(.semibold)
            }
            .font(.system(size: 11))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(color).frame(width: geometry.size.width * min(1, window.percent / 100))
                    if let elapsed { Rectangle().fill(NotchPalette.text.opacity(0.7)).frame(width: 1.5).offset(x: geometry.size.width * elapsed) }
                }
            }
            .frame(height: 5)
        }
    }

    /// "35m", "2h 2m", "3d 2h".
    static func left(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        return days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// Two shares side by side in one bar (Claude's and Codex's spending).
private struct SplitBar: View {
    let parts: [(Double, Color)]

    var body: some View {
        let total = max(parts.map(\.0).reduce(0, +), 0.0001)
        GeometryReader { geometry in
            HStack(spacing: 4) {
                ForEach(parts.indices.filter { parts[$0].0 > 0 }, id: \.self) { index in
                    Capsule().fill(parts[index].1).frame(width: max(3, (geometry.size.width - 2) * parts[index].0 / total))
                }
            }
        }
        .frame(height: 4)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .foregroundStyle(NotchPalette.text)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

private extension View {
    func cardTitle() -> some View { font(.system(size: 12, weight: .semibold)) }
}

/// Claude Code live (user's choice, 2026-11-02, after Pulsar's): each session busy lately — its
/// project, what it's doing now, its last steps, the files it changed with their diffs (a click
/// opens one). Claude orange, as the page's other Claude parts.
private struct LiveCard: View {
    let color: Color
    var store = AgentLiveStore.shared
    @State private var openFile: String?

    var body: some View {
        Card {
            HStack {
                Label { Text("Live") } icon: { Image(systemName: "sparkle").foregroundStyle(color) }.cardTitle()
                Spacer()
                if store.recent.contains(where: \.working) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text("working").font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                }
            }
            if store.recent.isEmpty {
                Text("What Claude Code does shows up here as it works: each step, and every file it changes.")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary)
            }
            ForEach(store.recent.prefix(2)) { session in sessionView(session) }
        }
    }

    private func sessionView(_ session: AgentLive.Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(session.project.isEmpty ? "Claude Code" : session.project).font(.system(size: 12, weight: .semibold))
                if let prompt = session.prompt {
                    Text(prompt).font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary).lineLimit(1)
                }
            }
            ForEach(session.steps.suffix(4)) { step in
                HStack(spacing: 8) {
                    Image(systemName: step.symbol).font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(step.running ? color : NotchPalette.tertiary)
                    Text(step.text).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(step.running ? NotchPalette.text : NotchPalette.secondary)
                    if step.running { ProgressView().controlSize(.mini) }
                }
            }
            if !session.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(session.files) { file in
                            Button { openFile = openFile == file.path ? nil : file.path } label: {
                                HStack(spacing: 4) {
                                    Text(file.name)
                                    Text("+\(file.added)").foregroundStyle(Color.green.opacity(0.85))
                                    Text("−\(file.removed)").foregroundStyle(Color.red.opacity(0.85))
                                }
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .padding(.horizontal, 8).frame(height: 20)
                                .background(Color.white.opacity(openFile == file.path ? 0.16 : 0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let path = openFile, let file = session.files.first(where: { $0.path == path }) { DiffView(file: file) }
            }
        }
    }
}

/// A file's edits, lines out in red and in in green, the last 40 lines.
private struct DiffView: View {
    let file: AgentLive.File

    var body: some View {
        let lines = file.changes.flatMap { change in change.removed.map { ("−", $0) } + change.added.map { ("+", $0) } }.suffix(40)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text("\(line.0) \(line.1)")
                    .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(line.0 == "+" ? Color.green.opacity(0.9) : Color.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background((line.0 == "+" ? Color.green : Color.red).opacity(0.08))
            }
        }
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }
}
