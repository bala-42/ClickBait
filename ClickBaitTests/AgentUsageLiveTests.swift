import ClickBaitCore
import Foundation
import Testing
@testable import ClickBait

/// The AI Agents data against this Mac's real logs and tools (opt-in: `TEST_RUNNER_CLICKBAIT_AGENTS_LIVE=1`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_AGENTS_LIVE"] != nil))
struct AgentUsageLiveTests {
    @Test func readsTheLogsAndAsksTheTools() throws {
        let reader = AgentLogReader()
        var start = Date()
        let (records, codex) = reader.read()
        let first = Date().timeIntervalSince(start)
        start = Date()
        _ = reader.read()
        let again = Date().timeIntervalSince(start)
        let prices = AgentPrices(json: try Data(contentsOf: try #require(Bundle(for: AgentUsageService.self as AnyClass? ?? NSObject.self).url(forResource: "agent-prices", withExtension: "json"))))
        let week = AgentSummary.of(records, period: .week, prices: prices)
        let today = AgentSummary.of(records, period: .today, prices: prices)
        let activity = AgentActivity.of(records, prices: prices)
        print("AGENTS records \(records.count) (claude \(records.filter { $0.tool == .claude }.count), codex \(records.filter { $0.tool == .codex }.count)); first read \(String(format: "%.1f", first)) s, again \(String(format: "%.2f", again)) s")
        print("AGENTS today $\(String(format: "%.2f", today.cost)), week $\(String(format: "%.2f", week.cost)), \(week.tokens) tokens, cache \(Int(week.cacheShare * 100))%, models \(week.models.map(\.name)), projects \(week.projects.map(\.name))")
        print("AGENTS 13 weeks $\(String(format: "%.0f", activity.total)), active days \(activity.activeDays), streak \(activity.streak), codex plan \(codex?.plan ?? "-")")
        let claude = AgentProbes.claudeUsage()
        print("AGENTS claude limits: plan \(claude?.plan ?? "-"), session \(claude?.session?.percent ?? -1)%, week \(claude?.week?.percent ?? -1)%")
        let account = AgentProbes.codexAccount()
        print("AGENTS codex account: plan \(account?.plan ?? "-"), resets \(account?.resets.map { "\($0.count)" } ?? "none")")
        #expect(!records.isEmpty && claude != nil)
    }
}
