import Testing
@testable import ClickBaitCore

struct CodeAnswerTests {
    @Test func spotsCodeQuestions() {
        #expect(CodeAnswer.wanted(question: "write a snake game in Python", selectedText: nil))
        #expect(CodeAnswer.wanted(question: "write a snake game", selectedText: nil))
        #expect(CodeAnswer.wanted(question: "fix this", selectedText: "for i in range(len(a) + 1):\n    print(a[i])"))
        #expect(CodeAnswer.wanted(question: "why does this crash?", selectedText: "let x: Int? = nil; print(x!)"))
        #expect(!CodeAnswer.wanted(question: "what's on my screen?", selectedText: nil))
        #expect(!CodeAnswer.wanted(question: "summarise this", selectedText: "The meeting moved to Tuesday at four."))
        #expect(!CodeAnswer.wanted(question: "where's the share button?", selectedText: nil))
    }

    @Test func markdownBecomesTheAnswer() throws {
        let json = CodeAnswer.json(fromMarkdown: "Here is a **palindrome** check:\n\n```Python\ndef p(s):\n    return s == s[::-1]\n```\nCall it with a word.")
        let parsed = ResponseParser.parse(json, imageWidth: 1280, imageHeight: 800)
        #expect(!parsed.usedFallback)
        #expect(parsed.response.speech == "Here is a palindrome check. Call it with a word.")
        #expect(parsed.response.code == "def p(s):\n    return s == s[::-1]")
        #expect(parsed.response.language == "python")
    }

    @Test func noBlockOrCutOff() {
        let words = ResponseParser.parse(CodeAnswer.json(fromMarkdown: "It force-unwraps nil."), imageWidth: 1, imageHeight: 1)
        #expect(words.response.speech == "It force-unwraps nil." && words.response.code == nil)
        let cut = ResponseParser.parse(CodeAnswer.json(fromMarkdown: "Here.\n```swift\nlet a = 1\nlet b"), imageWidth: 1, imageHeight: 1)
        #expect(cut.response.code == "let a = 1\nlet b")
    }

    @Test func noFormatForCode() {
        var ask = AskRequest(question: "write a game", screenshotJPEG: .init(), screenshotWidth: 0, screenshotHeight: 0, context: ScreenContext())
        ask.codeAnswer = true
        #expect(OllamaProvider.chatBody(for: ask, model: "m")["format"] == nil)
        #expect(Prompt.system(for: ask) == CodeAnswer.system)
    }
}
