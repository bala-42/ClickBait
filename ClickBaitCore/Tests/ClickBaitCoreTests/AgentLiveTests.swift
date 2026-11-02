import Foundation
import Testing
@testable import ClickBaitCore

struct AgentLiveTests {
    private func line(_ event: String, _ extra: String = "") -> String {
        #"{"tool":"claude","app":"com.apple.Terminal","event":{"session_id":"s1","cwd":"/Users/x/ClickBait","hook_event_name":"\#(event)"\#(extra)}}"#
    }

    @Test func followsATurn() throws {
        var live = AgentLive()
        live.see(line("UserPromptSubmit", #","prompt":"fix the notch\nplease""#))
        live.see(line("PreToolUse", #","tool_name":"Read","tool_input":{"file_path":"/a/NotchViews.swift"}"#))
        live.see(line("PreToolUse", #","tool_name":"Edit","tool_input":{"file_path":"/a/NotchViews.swift","old_string":"a\nb\nc","new_string":"a\nB\nd\nc"}"#))
        let session = try #require(live.sessions.first)
        #expect(session.project == "ClickBait" && session.prompt == "fix the notch")
        #expect(session.now == "Editing NotchViews.swift")
        #expect(session.steps.map(\.running) == [false, true])
        let file = try #require(session.files.first)
        #expect(file.removed == 1 && file.added == 2)  // "b" out; "B", "d" in (the shared "a" and "c" at the ends left out)
        live.see(line("Stop"))
        #expect(live.sessions.first?.now == nil && live.sessions.first?.working == false)
    }

    @Test func describesTools() {
        #expect(AgentLive.describe("Bash", ["command": "xcodebuild test -scheme ClickBait"]).0 == "Running: xcodebuild test -scheme ClickBait")
        #expect(AgentLive.describe("Grep", ["pattern": "pageSize"]).0 == "Searching for “pageSize”")
        #expect(AgentLive.describe("mcp__rea__open_binary", [:]).0 == "Using binary")
        var live = AgentLive()
        let taken = live.see(#"{"tool":"codex","event":{}}"#)
        #expect(!taken && live.sessions.isEmpty)
    }

    @Test func clockAndTurn() {
        #expect(AgentLive.clock(334) == "5:34" && AgentLive.clock(3723) == "1:02:03")
        let start = Date(timeIntervalSince1970: 1000)
        let records = [
            AgentUsageRecord(tool: .claude, model: "claude-opus-4-1", project: "ClickBait", date: start - 10, input: 0, output: 900, cacheRead: 0, cacheWrite: 0),
            AgentUsageRecord(tool: .claude, model: "claude-opus-4-1", project: "ClickBait", date: start + 5, input: 10, output: 1200, cacheRead: 0, cacheWrite: 0),
            AgentUsageRecord(tool: .claude, model: "claude-opus-4-1", project: "Other", date: start + 6, input: 0, output: 5000, cacheRead: 0, cacheWrite: 0),
        ]
        let turn = AgentLive.turn(records, project: "ClickBait", since: start, prices: AgentPrices(json: Data()))
        #expect(turn.written == 1200 && turn.model != nil)  // before the task and another project left out
    }

    @Test func followsACodexTask() throws {
        var live = AgentLive()
        let cwd = "/Applications/ClickBait"
        live.seeCodex(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#, session: "c1", cwd: cwd)
        live.seeCodex(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"<in-app-browser-context source=\"x\">page</in-app-browser-context>\nmake the key easy to find"}]}}}"#, session: "c1", cwd: cwd)
        live.seeCodex(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","command":["/bin/zsh","-lc","git status --short"]}}}"#, session: "c1", cwd: cwd)
        live.seeCodex(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","changes":{"/a/Settings.swift":{"type":"update","unified_diff":"@@ -1,2 +1,2 @@\n-old line\n+new line\n+another"}}}}}"#, session: "c1", cwd: cwd)
        let session = try #require(live.sessions.first)
        #expect(session.tool == .codex && session.project == "ClickBait" && session.prompt == "make the key easy to find")
        #expect(session.now == "Editing Settings.swift" && session.turnStarted != nil)
        #expect(session.files.first?.removed == 1 && session.files.first?.added == 2)
        live.seeCodex(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#, session: "c1", cwd: cwd)
        #expect(live.sessions.first?.working == false && live.sessions.first?.turnStarted == nil)
    }
}
