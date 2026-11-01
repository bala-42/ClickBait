import Foundation
import Testing
@testable import ClickBait

/// The notch's own chat against the real local model (opt-in: `TEST_RUNNER_CLICKBAIT_NOTCH_CHAT=<brain>`):
/// it answers, and a follow-up remembers the turn before.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_NOTCH_CHAT"] != nil))
struct NotchChatTests {
    @Test func remembersItsOwnTurns() async throws {
        let chat = NotchChat()
        chat.brain = { ProcessInfo.processInfo.environment["CLICKBAIT_NOTCH_CHAT"] ?? "" }
        func ask(_ text: String) async throws -> String {
            chat.send(text)
            let deadline = Date().addingTimeInterval(90)
            while chat.model.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
            return chat.model.messages.last?.text ?? ""
        }
        let first = try await ask("My cat is called Biscuit. Say hello to her in one short sentence.")
        let second = try await ask("What is my cat called? Answer with just the name.")
        print("NOTCH first: \(first)\nNOTCH second: \(second)")
        #expect(second.localizedCaseInsensitiveContains("biscuit"))
        chat.clear()
        #expect(chat.model.messages.isEmpty)
    }
}
