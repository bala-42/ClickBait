import Foundation
import Testing
@testable import ClickBaitCore

struct AgentNoticeTests {
    @Test func claudeHookLines() {
        let needs = AgentNotice.fromHookLine(#"{"tool":"claude","app":"com.apple.Terminal","event":{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","cwd":"/Users/me/ClickBait"}}"#)
        #expect(needs == AgentNotice(tool: .claude, kind: .needsYou(detail: "Claude needs your permission to use Bash"), project: "ClickBait", app: "com.apple.Terminal"))
        #expect(needs?.line == "Claude Code needs you · ClickBait")
        let done = AgentNotice.fromHookLine(#"{"tool":"claude","app":"","event":{"hook_event_name":"Stop","cwd":"/Users/me/landing"}}"#)
        #expect(done?.line == "Claude Code finished ✓ · landing" && done?.app == nil)
        #expect(AgentNotice.fromHookLine(#"{"tool":"claude","event":{"hook_event_name":"PreToolUse"}}"#) == nil)
        #expect(AgentNotice.fromHookLine("not json") == nil)
    }

    @Test func codexLogLines() {
        var cwd: String?
        #expect(AgentNotice.fromCodexLine(#"{"type":"session_meta","payload":{"cwd":"/Users/me/landing","id":"x"}}"#, cwd: &cwd) == nil)
        #expect(AgentNotice.fromCodexLine(#"{"type":"event_msg","payload":{"type":"token_count"}}"#, cwd: &cwd) == nil)
        let done = AgentNotice.fromCodexLine(#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"…"}}"#, cwd: &cwd)
        #expect(done?.line == "Codex finished ✓ · landing")
    }

    @Test func hooksGoBesideTheUsersAndComeOutClean() {
        let users: [String: Any] = ["theme": "dark", "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "my-stop.sh"]]]],
                                                               "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "guard.sh"]]]]]]
        let added = AgentHooks.adding(command: "'/Applications/ClickBait.app/Contents/Resources/clickbait-agent-event' claude", to: users)
        #expect(AgentHooks.isInstalled(in: added))
        let stop = (added["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 2)  // the user's own Stop hook kept
        #expect(!AgentHooks.isInstalled(in: users))
        let twice = AgentHooks.adding(command: "x clickbait-agent-event claude", to: added)
        #expect(((twice["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count == 2)  // never twice
        let removed = AgentHooks.removing(from: added)
        #expect(NSDictionary(dictionary: removed).isEqual(to: users))
        #expect(AgentHooks.removing(from: AgentHooks.adding(command: "clickbait-agent-event", to: [:])).isEmpty)
    }

    @Test func keepsOnlyWellFormedTTY() {
        let good = #"{"tool":"claude","app":"com.apple.Terminal","tty":"ttys003","event":{"hook_event_name":"Stop","cwd":"/x/ClickBait"}}"#
        #expect(AgentNotice.fromHookLine(good)?.tty == "ttys003")
        let bad = #"{"tool":"claude","tty":"ttys0\" & do shell script \"x","event":{"hook_event_name":"Stop"}}"#
        #expect(AgentNotice.fromHookLine(bad)?.tty == nil)
    }
}
