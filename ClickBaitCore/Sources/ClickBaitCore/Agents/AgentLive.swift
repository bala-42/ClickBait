import Foundation

/// Claude Code, live (user's choice, 2026-11-02, after Pulsar's): what each session is doing
/// now, its steps, and the files it changed with their diffs — from ClickBait's hook lines
/// (before each tool, and each prompt). A step counts as done when the next starts or the turn
/// stops. Pure: the app feeds lines and shows the result. Kept in memory only, for this run.
public struct AgentLive: Sendable {
    public struct Step: Equatable, Sendable, Identifiable {
        public let id: Int
        public let text: String
        public let symbol: String
        public var running: Bool
    }

    /// One edit: the lines it took out and put in.
    public struct Change: Equatable, Sendable {
        public let removed: [String]
        public let added: [String]
    }

    public struct File: Equatable, Sendable, Identifiable {
        public let path: String
        public var changes: [Change] = []
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
        public var added: Int { changes.reduce(0) { $0 + $1.added.count } }
        public var removed: Int { changes.reduce(0) { $0 + $1.removed.count } }
    }

    public struct Session: Equatable, Sendable, Identifiable {
        public let id: String
        /// Claude Code (its hooks) or Codex (its session logs).
        public var tool: AgentNotice.Tool = .claude
        public var project: String
        /// What it was asked, first line, short.
        public var prompt: String?
        public var steps: [Step] = []
        public var files: [File] = []
        public var working = false
        public var lastActive: Date
        /// When the running task began (its prompt), nil between tasks: the Now card's clock.
        public var turnStarted: Date?
        /// What it's doing now, or nil between turns.
        public var now: String? { working ? steps.last(where: \.running)?.text : nil }
    }

    public private(set) var sessions: [Session] = []
    private var nextStep = 0
    public static let keptSteps = 40
    public init() {}

    /// The busiest first: working, then the latest.
    public var ordered: [Session] {
        sessions.sorted { ($0.working ? 1 : 0, $0.lastActive) > ($1.working ? 1 : 0, $1.lastActive) }
    }

    /// One line of the events file; false when it wasn't about a session's work.
    @discardableResult
    public mutating func see(_ line: String, at now: Date = Date()) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["tool"] as? String == "claude",
              let event = object["event"] as? [String: Any],
              let id = event["session_id"] as? String, !id.isEmpty else { return false }
        let project = (event["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        var session = sessions.first { $0.id == id } ?? Session(id: id, project: project, lastActive: now)
        if !project.isEmpty { session.project = project }
        session.lastActive = now
        switch event["hook_event_name"] as? String {
        case "UserPromptSubmit":
            session.prompt = (event["prompt"] as? String).map(Self.firstLine)
            session.working = true
            session.turnStarted = now
            settle(&session)
        case "PreToolUse":
            let tool = event["tool_name"] as? String ?? "Tool"
            let input = event["tool_input"] as? [String: Any] ?? [:]
            settle(&session)
            session.working = true
            if session.turnStarted == nil { session.turnStarted = now }  // started before ClickBait was watching
            let (text, symbol) = Self.describe(tool, input)
            session.steps.append(Step(id: nextStep, text: text, symbol: symbol, running: true))
            nextStep += 1
            if session.steps.count > Self.keptSteps { session.steps.removeFirst(session.steps.count - Self.keptSteps) }
            Self.record(tool, input, in: &session)
        case "Stop":
            settle(&session)
            session.working = false
            session.turnStarted = nil
        default:
            return false
        }
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index] = session } else { sessions.append(session) }
        return true
    }

    /// A line of a Codex session log (`~/.codex/sessions/…`, user's ask, 2026-11-02: "live
    /// should show both Claude and Codex"): a task starting and finishing, the prompt, and each
    /// step as it completes — commands, tool calls, and file changes with their diffs. `session`
    /// names the log. Codex writes a step once done, so the latest is the one shown as current.
    @discardableResult
    public mutating func seeCodex(_ line: String, session id: String, cwd: String?, at now: Date = Date()) -> Bool {
        guard line.contains("task_") || line.contains("item_completed"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any] else { return false }
        var session = sessions.first { $0.id == id } ?? Session(id: id, tool: .codex, project: "", lastActive: now)
        if let cwd { session.project = (cwd as NSString).lastPathComponent }
        session.lastActive = now
        switch payload["type"] as? String {
        case "task_started":
            settle(&session)
            (session.working, session.turnStarted) = (true, now)
        case "task_complete":
            settle(&session)
            (session.working, session.turnStarted) = (false, nil)
        case "item_completed":
            guard let item = payload["item"] as? [String: Any] else { return false }
            switch item["type"] as? String {
            case "UserMessage":
                let texts = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                // Codex's app adds context blocks ("<in-app-browser-context …>…</…>"): the words after them.
                let said = texts.map { $0.replacingOccurrences(of: #"(?s)<([a-z-]+)[^>]*>.*?</\1>"#, with: "", options: .regularExpression) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.last
                if let said { session.prompt = Self.firstLine(said) }
            case "CommandExecution":
                let command = (item["command"] as? [String])?.last ?? ""
                step(&session, "Running: \(Self.short(command))", "terminal")
            case "McpToolCall":
                let what = (item["arguments"] as? [String: Any])?["title"] as? String ?? item["tool"] as? String ?? "a tool"
                step(&session, Self.short(what), "wrench.and.screwdriver")
            case "FileChange":
                for (path, value) in item["changes"] as? [String: Any] ?? [:] {
                    let diff = (value as? [String: Any])?["unified_diff"] as? String ?? ""
                    let lines = diff.components(separatedBy: "\n")
                    let change = Change(removed: lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.map { String($0.dropFirst()) },
                                        added: lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.map { String($0.dropFirst()) })
                    step(&session, "Editing \((path as NSString).lastPathComponent)", "pencil")
                    if let index = session.files.firstIndex(where: { $0.path == path }) { session.files[index].changes.append(change) }
                    else { session.files.append(File(path: path, changes: [change])) }
                }
            default:
                return false
            }
        default:
            return false
        }
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index] = session } else { sessions.append(session) }
        return true
    }

    private mutating func step(_ session: inout Session, _ text: String, _ symbol: String) {
        settle(&session)
        if session.turnStarted == nil { (session.working, session.turnStarted) = (true, session.lastActive) }
        session.steps.append(Step(id: nextStep, text: text, symbol: symbol, running: true))
        nextStep += 1
        if session.steps.count > Self.keptSteps { session.steps.removeFirst(session.steps.count - Self.keptSteps) }
    }

    /// The Now card's clock: "5:34", "1:02:03".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds)), hours = total / 3600
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, total % 3600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The Now card's bottom line for a running task: its model, the tokens it wrote and their
    /// cost, from Claude Code's usage since the task began in that project.
    public static func turn(_ records: [AgentUsageRecord], tool: AgentNotice.Tool = .claude, project: String, since: Date,
                            prices: AgentPrices) -> (model: String?, written: Int, cost: Double) {
        let mine = records.filter { $0.tool == tool && $0.project == project && $0.date >= since }
        return (mine.max { $0.date < $1.date }.map { AgentPrices.displayName($0.model) },
                mine.reduce(0) { $0 + $1.output }, mine.reduce(0) { $0 + prices.cost($1) })
    }

    private func settle(_ session: inout Session) {
        for index in session.steps.indices { session.steps[index].running = false }
    }

    /// "Editing NotchViews.swift", "Running: xcodebuild test…", "Searching for “pageSize”".
    public static func describe(_ tool: String, _ input: [String: Any]) -> (String, String) {
        let file = (input["file_path"] as? String ?? input["path"] as? String).map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit": return ("Editing \(file ?? "a file")", "pencil")
        case "Write": return ("Writing \(file ?? "a file")", "doc.badge.plus")
        case "Read": return ("Reading \(file ?? "a file")", "doc.text")
        case "Bash": return ("Running: \(short(input["command"] as? String ?? ""))", "terminal")
        case "Grep": return ("Searching for “\(short(input["pattern"] as? String ?? "", 40))”", "magnifyingglass")
        case "Glob": return ("Looking for \(short(input["pattern"] as? String ?? "files", 40))", "folder")
        case "WebFetch", "WebSearch": return ("Looking up \(short(input["query"] as? String ?? input["url"] as? String ?? "the web", 40))", "globe")
        case "Task", "Agent": return ("Handing off: \(short(input["description"] as? String ?? "a task", 40))", "person.2")
        case "TodoWrite": return ("Planning", "checklist")
        default:
            let name = tool.hasPrefix("mcp__") ? (tool.split(separator: "_").last.map(String.init) ?? tool) : tool
            return ("Using \(name)", "wrench.and.screwdriver")
        }
    }

    /// An edit's lines out and in, kept on its file.
    private static func record(_ tool: String, _ input: [String: Any], in session: inout Session) {
        guard let path = input["file_path"] as? String else { return }
        var changes: [Change] = []
        switch tool {
        case "Edit":
            changes = [change(input["old_string"] as? String, input["new_string"] as? String)]
        case "MultiEdit":
            changes = (input["edits"] as? [[String: Any]] ?? []).map { change($0["old_string"] as? String, $0["new_string"] as? String) }
        case "Write":
            changes = [change(nil, input["content"] as? String)]
        default:
            return
        }
        if let index = session.files.firstIndex(where: { $0.path == path }) {
            session.files[index].changes += changes
        } else {
            session.files.append(File(path: path, changes: changes))
        }
    }

    /// Lines out and in, the ones both share at the ends left out.
    static func change(_ old: String?, _ new: String?) -> Change {
        var removed = old.map { $0.components(separatedBy: "\n") } ?? []
        var added = new.map { $0.components(separatedBy: "\n") } ?? []
        while let a = removed.first, let b = added.first, a == b { removed.removeFirst(); added.removeFirst() }
        while let a = removed.last, let b = added.last, a == b { removed.removeLast(); added.removeLast() }
        return Change(removed: removed, added: added)
    }

    private static func firstLine(_ text: String) -> String {
        short(text.split(separator: "\n").first.map(String.init) ?? text, 80)
    }

    private static func short(_ text: String, _ limit: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
