import Foundation
import Testing
@testable import ClickBaitCore

struct NextSuggestionsTests {
    @Test func keepsTwoShortDistinctOnes() {
        let reply = #"{"next": ["show me the fixed code", "Why is it nil?", "Explain optionals"]}"#
        #expect(NextSuggestions.parse(reply, question: "why does this crash") == ["Show me the fixed code", "Why is it nil?"])
    }

    @Test func dropsRepeatsTheQuestionAndLongOnes() {
        let long = String(repeating: "very ", count: 12) + "long"
        let reply = #"{"next": ["Why does this crash?", "  ", "\#(long)", "Fix it", "fix it!"]}"#
        #expect(NextSuggestions.parse(reply, question: "why does this crash") == ["Fix it"])
    }

    @Test func notAReplyIsNil() {
        #expect(NextSuggestions.parse("sure! here are some ideas", question: "x") == nil)
        #expect(NextSuggestions.parse(#"{"query": "x"}"#, question: "x") == nil)
    }

    @Test func requestIsTextOnlyWithItsOwnPrompt() {
        var ask = AskRequest(question: "why does this crash", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: ScreenContext(appName: nil), selectedText: nil)
        ask.suggestNextAfter = "It's nil until Settings load."
        #expect(Prompt.system(for: ask) == Prompt.nextSystem)
        #expect(Prompt.userText(for: ask) == "Question: why does this crash\nAnswer: It's nil until Settings load.")
        let schema = OllamaProvider.schema(for: ask)
        #expect((schema?["required"] as? [String]) == ["next"])
    }
}
