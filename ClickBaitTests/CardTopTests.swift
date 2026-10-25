import ClickBaitCore
import Testing
@testable import ClickBait

/// After a follow-up in a dock card, its answer shows once, in the mini-chat; the card's top
/// keeps the first question and answer (user's report, 2026-10-25).
@MainActor
struct CardTopTests {
    @Test func aFollowUpDoesNotReplaceTheTop() {
        var job = BackgroundJob(question: "write a snake game", kind: .answer, homeBundleID: nil, homePID: nil, conversation: Conversation())
        job.complete(answer: "Here's a snake game.", conversation: Conversation())
        #expect(CapsuleView.top(of: job, messages: []) == ("write a snake game", "Here's a snake game."))

        job.reopen(asking: "make it faster")
        job.complete(answer: "Lower the delay to 0.05.", conversation: Conversation())
        let messages = [
            ChatModel.Message(role: .user, text: "write a snake game"),
            ChatModel.Message(role: .assistant, text: "Here's a snake game."),
            ChatModel.Message(role: .user, text: "make it faster"),
            ChatModel.Message(role: .assistant, text: "Lower the delay to 0.05."),
        ]
        let top = CapsuleView.top(of: job, messages: messages)
        #expect(top.question == "write a snake game")
        #expect(top.answer == "Here's a snake game.")
    }
}
