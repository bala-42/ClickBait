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
        public var project: String
        /// What it was asked, first line, short.
        public var prompt: String?
        public var steps: [Step] = []
        public var files: [File] = []
        public var working = false
        public var lastActive: Date
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
            settle(&session)
        case "PreToolUse":
            let tool = event["tool_name"] as? String ?? "Tool"
            let input = event["tool_input"] as? [String: Any] ?? [:]
            settle(&session)
            session.working = true
            let (text, symbol) = Self.describe(tool, input)
            session.steps.append(Step(id: nextStep, text: text, symbol: symbol, running: true))
            nextStep += 1
            if session.steps.count > Self.keptSteps { session.steps.removeFirst(session.steps.count - Self.keptSteps) }
            Self.record(tool, input, in: &session)
        case "Stop":
            settle(&session)
            session.working = false
        default:
            return false
        }
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index] = session } else { sessions.append(session) }
        return true
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
