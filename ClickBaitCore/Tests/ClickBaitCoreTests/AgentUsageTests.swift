import Foundation
import Testing
@testable import ClickBaitCore

struct AgentUsageTests {
    let prices = AgentPrices(json: Data("""
        {"claude":{"models":[{"id":"claude-opus-5-5","input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25}]},
         "codex":{"models":[{"id":"gpt-6","input":1,"output":8,"cacheRead":0.1,"cacheWrite":0},{"id":"gpt-6-luna","input":2,"output":10,"cacheRead":0.2,"cacheWrite":0}]}}
        """.utf8))

    @Test func claudeLines() throws {
        let line = #"{"type":"assistant","timestamp":"2026-11-02T10:00:00.000Z","requestId":"r1","cwd":"/Users/me/ClickBait","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation_input_tokens":300}}}"#
        let (key, record) = try #require(AgentUsageRecord.fromClaudeLine(line))
        #expect(key == "m1|r1" && record.project == "ClickBait" && record.tokens == 5510)
        // 10×5 + 200×25 + 5000×0.5 + 300×6.25 = 9425 per million
        #expect(abs(prices.cost(record) - 0.009425) < 1e-9)
        #expect(AgentUsageRecord.fromClaudeLine(#"{"type":"user","message":{"content":"hi"}}"#) == nil)
    }

    @Test func codexLines() {
        var model: String?, cwd: String?, total = 0, limits: CodexLimits?
        _ = AgentUsageRecord.fromCodexLine(#"{"type":"turn_context","payload":{"model":"gpt-6-luna","cwd":"/Users/me/landing"}}"#, model: &model, cwd: &cwd, lastTotal: &total, limits: &limits)
        let count = #"{"timestamp":"2026-11-02T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1000},"last_token_usage":{"input_tokens":900,"cached_input_tokens":800,"output_tokens":100}},"rate_limits":{"plan_type":"plus","primary":{"used_percent":78,"resets_in_seconds":3600}}}}"#
        let record = AgentUsageRecord.fromCodexLine(count, model: &model, cwd: &cwd, lastTotal: &total, limits: &limits)
        #expect(record?.input == 100 && record?.cacheRead == 800 && record?.project == "landing" && record?.model == "gpt-6-luna")
        #expect(limits?.limits.plan == "Plus" && limits?.limits.session?.percent == 78)
        // The same count again (nothing changed): not counted twice.
        #expect(AgentUsageRecord.fromCodexLine(count, model: &model, cwd: &cwd, lastTotal: &total, limits: &limits) == nil)
        #expect(prices.price(for: "gpt-6-luna")?.input == 2)  // longest match, not "gpt-6"
    }

    @Test func claudeLimits() {
        let usage: [String: Any] = ["subscription_type": "max_5x", "rate_limits_available": true,
                                    "rate_limits": ["five_hour": ["utilization": 81, "resets_at": "2026-11-02T08:49:59.994697+00:00"],
                                                    "seven_day": ["utilization": 66, "resets_at": "2026-11-07T13:59:59+00:00"]]]
        let limits = AgentLimits.claude(usage: usage)
        #expect(limits?.plan == "Max 5×" && limits?.session?.percent == 81 && limits?.week?.percent == 66)
        #expect(limits?.week?.resets != nil)
        #expect(AgentLimits.claudeApp(history: Data(#"{"version":2,"samples":[{"t":1,"u":{"fh":37,"sd":30}}]}"#.utf8))?.session?.percent == 37)
    }

    @Test func summaryAndActivity() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_620_800)  // 2026-11-02 12:00 UTC
        let records = [
            AgentUsageRecord(tool: .claude, model: "claude-opus-5-5", project: "ClickBait", date: now.addingTimeInterval(-3600), input: 0, output: 1_000_000, cacheRead: 0, cacheWrite: 0),
            AgentUsageRecord(tool: .codex, model: "gpt-6-luna", project: "landing", date: now.addingTimeInterval(-86_400), input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0),
        ]
        let today = AgentSummary.of(records, period: .today, prices: prices, now: now, calendar: calendar)
        #expect(today.cost == 25 && today.trend[11][.claude] == 25 && today.models.first?.name == "Opus 5.5")
        let week = AgentSummary.of(records, period: .week, prices: prices, now: now, calendar: calendar)
        #expect(week.cost == 27 && week.projects.map(\.name) == ["ClickBait", "landing"])
        let activity = AgentActivity.of(records, prices: prices, now: now, calendar: calendar)
        #expect(activity.activeDays == 2 && activity.streak == 2 && activity.busiest?.cost == 25)
    }

    @Test func names() {
        #expect(AgentPrices.displayName("claude-opus-5-5") == "Opus 5.5")
        #expect(AgentPrices.displayName("gpt-6.1-sol") == "GPT-6.1 Sol")
        #expect(AgentLimits.planName("pro") == "Pro")
    }
}
