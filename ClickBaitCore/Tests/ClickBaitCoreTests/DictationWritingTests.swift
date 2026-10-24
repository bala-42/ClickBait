import Testing
@testable import ClickBaitCore

struct DictationWritingTests {
    private func plan(_ heard: String, selection: Bool = false, last: Bool = false, field: Bool = false) -> DictationWriting.Plan {
        DictationWriting.plan(heard: heard, hasSelection: selection, hasLastResult: last, fieldHasText: field)
    }

    @Test func plainWordsAreTyped() {
        #expect(plan("see you at three tomorrow") == .type("see you at three tomorrow"))
        #expect(plan("make sure to bring snacks") == .type("make sure to bring snacks"))
        #expect(plan("we need more formal training") == .type("we need more formal training"))
    }

    @Test func typeAlwaysTypes() {
        #expect(plan("type reply all when you can") == .type("reply all when you can"))
        #expect(plan("type make it shorter", selection: true) == .type("make it shorter"))
    }

    @Test func anythingSaidOverASelectionReworksIt() {
        #expect(plan("make this punchier", selection: true) == .write(instruction: "make this punchier", subject: .selection))
        #expect(plan("in spanish please", selection: true) == .write(instruction: "in spanish please", subject: .selection))
    }

    @Test func requestsWriteFromTheScreen() {
        #expect(plan("reply to this email and ask what they use it for") == .write(
            instruction: "reply to this email and ask what they use it for", subject: .screen))
        #expect(plan("write a thank you note to Sam") == .write(instruction: "write a thank you note to Sam", subject: .screen))
    }

    @Test func itIsTheLastResultThenTheDraftThenTheScreen() {
        let ask = "give it to me in point form"
        #expect(plan(ask, last: true, field: true) == .write(instruction: ask, subject: .lastResult))
        #expect(plan(ask, field: true) == .write(instruction: ask, subject: .field))
        #expect(plan(ask) == .write(instruction: ask, subject: .screen))
        #expect(plan("make it more formal", field: true) == .write(instruction: "make it more formal", subject: .field))
    }

    @Test func parsesOnlyRealText() {
        #expect(DictationWriting.parse(#"{"text": "• One\n• Two"}"#) == "• One\n• Two")
        #expect(DictationWriting.parse(#"{"text": ""}"#) == nil)
        #expect(DictationWriting.parse("sorry") == nil)
    }
}
