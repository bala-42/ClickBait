import Foundation

/// Claude Code and Codex telling the user something (user's ask, 2026-11-02: "a notification …
/// that the claude code or the codex needs an action from the user or … that task has
/// completed"). Claude Code through its own hooks (Notification, Stop), which append a line to
/// ClickBait's events file; Codex from its session logs (`task_complete`), since its single
/// `notify` setting already belongs to another app.
public struct AgentNotice: Equatable, Sendable {
    public enum Tool: String, Sendable, Codable { case claude, codex }
    public enum Kind: Equatable, Sendable {
        /// Waiting on the user: a permission, a question. `detail`: what it said, if anything.
        case needsYou(detail: String?)
        case finished
    }

    public let tool: Tool
    public let kind: Kind
    /// The project folder's name ("ClickBait"), if known.
    public let project: String?
    /// The app it runs in (Terminal, iTerm, VS Code, the Claude app), as its bundle identifier.
    public let app: String?
    /// The terminal tab it runs in ("ttys000"), so "go there" can bring that very tab forward
    /// (user's ask, 2026-11-02). Only a well-formed tty name is kept.
    public var tty: String? = nil

    public var toolName: String { tool == .claude ? "Claude Code" : "Codex" }

    /// The pill's words, small letters with names kept ("Claude Code needs you · ClickBait").
    public var line: String {
        let suffix = project.map { " · \($0)" } ?? ""
        switch kind {
        case .needsYou: return "\(toolName) needs you\(suffix)"
        case .finished: return "\(toolName) finished ✓\(suffix)"
        }
    }

    /// One line of the events file the hook script writes:
    /// `{"tool":"claude","app":"com.apple.Terminal","event":{…Claude Code's hook JSON…}}`.
    public static func fromHookLine(_ line: String) -> AgentNotice? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = (object["tool"] as? String).flatMap(Tool.init(rawValue:)),
              let event = object["event"] as? [String: Any] else { return nil }
        let app = (object["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let project = (event["cwd"] as? String).map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let tty = (object["tty"] as? String).flatMap { $0.range(of: #"^ttys?\d{1,4}$"#, options: .regularExpression) != nil ? $0 : nil }
        switch event["hook_event_name"] as? String {
        case "Notification": return AgentNotice(tool: tool, kind: .needsYou(detail: event["message"] as? String), project: project, app: app, tty: tty)
        case "Stop": return AgentNotice(tool: tool, kind: .finished, project: project, app: app, tty: tty)
        default: return nil
        }
    }

    /// A Codex session log line: its finished turns, and the folder it works in (from the
    /// session's first line or a turn's context), which later lines don't repeat.
    public static func fromCodexLine(_ line: String, cwd: inout String?) -> AgentNotice? {
        // Cheap test first: these logs run to tens of thousands of lines.
        guard line.contains("task_complete") || line.contains("\"cwd\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = object["payload"] as? [String: Any]
        if let folder = payload?["cwd"] as? String { cwd = folder }
        guard object["type"] as? String == "event_msg", payload?["type"] as? String == "task_complete" else { return nil }
        return AgentNotice(tool: .codex, kind: .finished, project: cwd.map { ($0 as NSString).lastPathComponent }, app: nil)
    }
}

/// ClickBait's hooks in Claude Code's settings (`~/.claude/settings.json`): added beside the
/// user's own, never replacing them, and found again by the script's name to take out.
public enum AgentHooks {
    /// Needs you and finished (notices), and before each tool and each prompt (the live view,
    /// `AgentLive`; user's choice, 2026-11-02).
    public static let events = ["Notification", "Stop", "PreToolUse", "UserPromptSubmit"]
    public static let marker = "clickbait-agent-event"

    /// `settings` with ClickBait's hook for each event (once), the rest as it was.
    public static func adding(command: String, to settings: [String: Any]) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["matcher": "", "hooks": [["type": "command", "command": command]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// `settings` without ClickBait's hooks; groups and events left empty by that go too.
    public static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        var settings = settings
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let others = entries.filter { !(($0["command"] as? String) ?? "").contains(marker) }
                if others.count == entries.count { return group }
                if others.isEmpty { return nil }
                var group = group
                group["hooks"] = others
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    public static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { (($0["command"] as? String) ?? "").contains(marker) }
            }
        }
    }
}
