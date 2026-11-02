import Foundation

/// Claude Code and Codex usage for the AI Agents page (user's ask, 2026-11-02, after Vorssaint's):
/// token counters read from their session logs on this Mac, priced at the providers' published
/// API rates. Only counters, model names, times and folder names; never prompts or replies.
public struct AgentUsageRecord: Equatable, Sendable, Codable {
    public let tool: AgentNotice.Tool
    public let model: String
    public let project: String?
    public let date: Date
    /// Input not read from cache, output (reasoning included), cache reads and writes.
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int

    public var tokens: Int { input + output + cacheRead + cacheWrite }

    public init(tool: AgentNotice.Tool, model: String, project: String?, date: Date, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
        (self.tool, self.model, self.project, self.date) = (tool, model, project, date)
        (self.input, self.output, self.cacheRead, self.cacheWrite) = (input, output, cacheRead, cacheWrite)
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A Claude Code log line with a model reply's usage, and its key: a reply is logged more
    /// than once (a line per part), so the key (message and request ids) counts it once.
    public static func fromClaudeLine(_ line: String) -> (key: String, record: AgentUsageRecord)? {
        guard line.contains("\"usage\""), let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let model = message["model"] as? String, model.hasPrefix("claude"),
              let usage = message["usage"] as? [String: Any],
              let date = date(object["timestamp"] as? String) else { return nil }
        let int = { (key: String) in (usage[key] as? NSNumber)?.intValue ?? 0 }
        let key = "\(message["id"] as? String ?? "")|\(object["requestId"] as? String ?? "")"
        let project = (object["cwd"] as? String).map { ($0 as NSString).lastPathComponent }
        return (key, AgentUsageRecord(tool: .claude, model: model, project: project, date: date, input: int("input_tokens"),
                                      output: int("output_tokens"), cacheRead: int("cache_read_input_tokens"),
                                      cacheWrite: int("cache_creation_input_tokens")))
    }

    /// A Codex log line: a turn's context sets the model and folder; a token count adds its last
    /// turn's usage, once (Codex repeats a count when nothing changed: its running total is the
    /// key). Rate limits, when the plan has them, come along (`CodexLimits`).
    public static func fromCodexLine(_ line: String, model: inout String?, cwd: inout String?, lastTotal: inout Int,
                                     limits: inout CodexLimits?) -> AgentUsageRecord? {
        guard line.contains("token_count") || line.contains("turn_context") || line.contains("session_meta") else { return nil }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        if let folder = payload["cwd"] as? String { cwd = folder }
        if object["type"] as? String == "turn_context", let name = payload["model"] as? String { model = name }
        guard object["type"] as? String == "event_msg", payload["type"] as? String == "token_count" else { return nil }
        let date = date(object["timestamp"] as? String) ?? Date()
        if let rates = payload["rate_limits"] as? [String: Any] { limits = CodexLimits(rates, at: date) }
        guard let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let total = ((info["total_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber)?.intValue,
              total != lastTotal else { return nil }
        lastTotal = total
        let int = { (key: String) in (last[key] as? NSNumber)?.intValue ?? 0 }
        let cached = int("cached_input_tokens")
        return AgentUsageRecord(tool: .codex, model: model ?? "gpt", project: cwd.map { ($0 as NSString).lastPathComponent }, date: date,
                                input: max(0, int("input_tokens") - cached), output: int("output_tokens"),
                                cacheRead: cached, cacheWrite: int("cache_write_input_tokens"))
    }
}

/// A plan's allowance windows: the 5-hour session and the week, how much is used and when each
/// starts afresh.
public struct AgentLimits: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let percent: Double
        public let resets: Date?
    }
    public let plan: String?
    public let session: Window?
    public let week: Window?

    public init(plan: String?, session: Window?, week: Window?) { (self.plan, self.session, self.week) = (plan, session, week) }

    /// Claude Code's `get_usage` answer (the account-wide limits, the same as /usage).
    public static func claude(usage response: [String: Any]) -> AgentLimits? {
        guard response["rate_limits_available"] as? Bool == true, let limits = response["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let entry = limits[key] as? [String: Any], let used = (entry["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Window(percent: used, resets: AgentUsageRecord.date(entry["resets_at"] as? String))
        }
        let plan = (response["subscription_type"] as? String).map(planName)
        return AgentLimits(plan: plan, session: window("five_hour"), week: window("seven_day"))
    }

    /// The Claude app's own record of the limits (`plan-usage-history.json`), when Claude Code
    /// can't be asked: the newest sample's 5-hour (`fh`) and 7-day (`sd`) percentages, no resets.
    public static func claudeApp(history data: Data) -> AgentLimits? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latest = (object["samples"] as? [[String: Any]])?.last,
              let used = latest["u"] as? [String: Any] else { return nil }
        let percent = { (key: String) in (used[key] as? NSNumber).map { Window(percent: $0.doubleValue, resets: nil) } }
        return AgentLimits(plan: nil, session: percent("fh"), week: percent("sd"))
    }

    /// "max_5x" → "Max 5×", "pro" → "Pro".
    public static func planName(_ raw: String) -> String {
        raw.split(separator: "_").map { part -> String in
            if part.hasSuffix("x"), part.dropLast().allSatisfy(\.isNumber) { return part.dropLast() + "×" }
            return part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }
}

/// Codex's limits from its logs' token counts: the plan and, on plans that have them, the
/// session (primary) and weekly (secondary) windows.
public struct CodexLimits: Equatable, Sendable {
    public let limits: AgentLimits

    init?(_ rates: [String: Any], at date: Date) {
        func window(_ key: String) -> AgentLimits.Window? {
            guard let entry = rates[key] as? [String: Any], let used = (entry["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                ?? (entry["resets_in_seconds"] as? NSNumber).map { date.addingTimeInterval($0.doubleValue) }
            return AgentLimits.Window(percent: used, resets: resets)
        }
        limits = AgentLimits(plan: (rates["plan_type"] as? String).map(AgentLimits.planName), session: window("primary"), week: window("secondary"))
    }
}

/// The providers' published API prices, US dollars per million tokens (Vorssaint's list,
/// GPL-3.0, `agent-prices.json`): what the usage would have cost on the API.
public struct AgentPrices: Sendable {
    public struct Price: Equatable, Sendable {
        public let input, output, cacheRead, cacheWrite: Double
    }
    let models: [(id: String, price: Price)]

    public init(json data: Data) {
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        models = ["claude", "codex"].flatMap { key -> [(String, Price)] in
            ((object[key] as? [String: Any])?["models"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                let number = { (key: String) in (entry[key] as? NSNumber)?.doubleValue ?? 0 }
                return (id, Price(input: number("input"), output: number("output"), cacheRead: number("cacheRead"), cacheWrite: number("cacheWrite")))
            }
        }
        // Longest first, so "gpt-6.1-sol" wins over "gpt-6".
        .sorted { $0.0.count > $1.0.count }
    }

    /// The model's price: its exact name, else the longest listed name it starts with
    /// ("claude-opus-5-5-20261001" → "claude-opus-5-5").
    public func price(for model: String) -> Price? {
        let name = model.lowercased()
        return models.first { name == $0.id }?.price ?? models.first { name.hasPrefix($0.id + "-") }?.price
    }

    public func cost(_ record: AgentUsageRecord) -> Double {
        guard let price = price(for: record.model) else { return 0 }
        return (Double(record.input) * price.input + Double(record.output) * price.output
                + Double(record.cacheRead) * price.cacheRead + Double(record.cacheWrite) * price.cacheWrite) / 1_000_000
    }

    /// "claude-opus-5-5" → "Opus 5.5", "gpt-6.1-sol" → "GPT-6.1 Sol".
    public static func displayName(_ model: String) -> String {
        if model.hasPrefix("claude-") {
            let parts = String(model.dropFirst(7)).split(separator: "-").map(String.init)
                .filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }  // a snapshot date
            guard let family = parts.first else { return model }
            let version = parts.dropFirst().joined(separator: ".")
            return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
        }
        if model.hasPrefix("gpt-") {
            let parts = model.split(separator: "-")
            let version = parts.count > 1 ? "GPT-" + parts[1] : "GPT"
            return ([version] + parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined(separator: " ")
        }
        return model
    }
}

/// What the page shows for a period, from the records.
public struct AgentSummary: Equatable, Sendable {
    public enum Period: String, CaseIterable, Sendable { case today, week, month }

    public let cost: Double
    public let costByTool: [AgentNotice.Tool: Double]
    public let tokens: Int
    /// Share of the tokens the model read from cache (0…1).
    public let cacheShare: Double
    /// Bars: hours of today, or days of the week or month; each with its cost per tool.
    public let trend: [[AgentNotice.Tool: Double]]
    public let models: [(name: String, cost: Double)]
    public let projects: [(name: String, cost: Double)]

    public static func == (a: AgentSummary, b: AgentSummary) -> Bool {
        a.cost == b.cost && a.tokens == b.tokens && a.trend == b.trend
            && a.models.map(\.name) == b.models.map(\.name) && a.projects.map(\.name) == b.projects.map(\.name)
    }

    public static func of(_ records: [AgentUsageRecord], period: Period, prices: AgentPrices, now: Date = Date(),
                          calendar: Calendar = .current) -> AgentSummary {
        let start: Date = switch period {
        case .today: calendar.startOfDay(for: now)
        case .week: calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .month: calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        }
        let chosen = records.filter { $0.date >= start && $0.date <= now }
        let buckets = period == .today ? 24 : period == .week ? 7 : 30
        var trend = Array(repeating: [AgentNotice.Tool: Double](), count: buckets)
        var byTool: [AgentNotice.Tool: Double] = [:], byModel: [String: Double] = [:], byProject: [String: Double] = [:]
        var tokens = 0, cached = 0, total = 0.0
        for record in chosen {
            let cost = prices.cost(record)
            total += cost
            byTool[record.tool, default: 0] += cost
            byModel[AgentPrices.displayName(record.model), default: 0] += cost
            if let project = record.project { byProject[project, default: 0] += cost }
            tokens += record.tokens
            cached += record.cacheRead
            let index = period == .today ? calendar.component(.hour, from: record.date)
                : (calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: record.date)).day ?? 0)
            if trend.indices.contains(index) { trend[index][record.tool, default: 0] += cost }
        }
        let top = { (map: [String: Double]) in map.sorted { $0.value > $1.value }.prefix(3).map { (name: $0.key, cost: $0.value) } }
        return AgentSummary(cost: total, costByTool: byTool, tokens: tokens, cacheShare: tokens > 0 ? Double(cached) / Double(tokens) : 0,
                            trend: trend, models: top(byModel), projects: top(byProject))
    }
}

/// Thirteen weeks of days (the Activity card): each day's cost, the total, days with any use,
/// the busiest day, and the run of days in a row up to today.
public struct AgentActivity: Equatable, Sendable {
    public let days: [Double]
    public let total: Double
    public let activeDays: Int
    public let busiest: (date: Date, cost: Double)?
    public let streak: Int

    public static func == (a: AgentActivity, b: AgentActivity) -> Bool { a.days == b.days && a.streak == b.streak }

    public static func of(_ records: [AgentUsageRecord], prices: AgentPrices, now: Date = Date(), calendar: Calendar = .current) -> AgentActivity {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -90, to: today) ?? today
        var days = Array(repeating: 0.0, count: 91)
        for record in records where record.date >= start {
            let index = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: record.date)).day ?? -1
            if days.indices.contains(index) { days[index] += prices.cost(record) }
        }
        let busiestIndex = days.indices.max { days[$0] < days[$1] }
        let busiest = busiestIndex.flatMap { days[$0] > 0 ? (calendar.date(byAdding: .day, value: $0, to: start) ?? start, days[$0]) : nil }
        var streak = 0
        for cost in days.reversed() { if cost > 0 { streak += 1 } else { break } }
        return AgentActivity(days: days, total: days.reduce(0, +), activeDays: days.filter { $0 > 0 }.count, busiest: busiest, streak: streak)
    }
}
