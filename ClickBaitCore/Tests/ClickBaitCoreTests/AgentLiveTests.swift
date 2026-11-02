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
}
