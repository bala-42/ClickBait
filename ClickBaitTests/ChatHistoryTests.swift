import Testing
@testable import ClickBait

/// One conversation for the session, whichever way it's opened (⌃⌥, ⌥⌘, the notch).
@MainActor
struct ChatHistoryTests {
    @Test func aNewChatKeepsWhatCameBefore() {
        let model = ChatModel()
        model.addUser("first question")
        model.setAssistant("first answer")
        model.startSession()
        model.addUser("second question")
        #expect(model.messages.map(\.text) == ["first question", "first answer", "second question"])
        #expect(model.current.map(\.text) == ["second question"])  // what Save keeps and the dock takes
        model.clearHistory()
        #expect(model.messages.isEmpty && model.current.isEmpty)
    }

    @Test func historyIsCapped() {
        let model = ChatModel()
        for index in 0..<(ChatModel.historyLimit + 10) { model.addUser("q\(index)") }
        model.startSession()
        #expect(model.messages.count == ChatModel.historyLimit && model.current.isEmpty)
    }
}
