import Testing
@testable import ClickBaitCore

struct MessageFormatTests {
    private let reply = """
        Use VLOOKUP like this:
        ```excel
        =VLOOKUP(A2, Sheet2!A:B, 2, FALSE)
        ```
        Then drag it down the column.
        """

    @Test func splitsProseAndCode() {
        #expect(MessageFormat.segments(reply) == [
            .text("Use VLOOKUP like this:"),
            .code(language: "excel", code: "=VLOOKUP(A2, Sheet2!A:B, 2, FALSE)"),
            .text("Then drag it down the column."),
        ])
    }

    @Test func plainTextIsOneSegment() {
        #expect(MessageFormat.segments("Click Share.") == [.text("Click Share.")])
        #expect(MessageFormat.segments("") == [])
    }

    @Test func unclosedFenceRunsToTheEndWhileStreaming() {
        #expect(MessageFormat.segments("Try:\n```swift\nlet x = 1\nlet y") == [
            .text("Try:"), .code(language: "swift", code: "let x = 1\nlet y"),
        ])
    }

    @Test func codeWithoutLanguageKeepsIndentation() {
        #expect(MessageFormat.segments("```\nif x {\n    y()\n}\n```") == [.code(language: nil, code: "if x {\n    y()\n}")])
    }

    @Test func spokenTextSkipsCode() {
        #expect(MessageFormat.spokenText(reply) == "Use VLOOKUP like this: Then drag it down the column.")
    }
}

struct CodeFenceFilterTests {
    private let reply = "Use this:\n```python\nprint(\"hi\")\n```\nThen run it."

    private func filter(_ chunks: [String]) -> String {
        var filter = CodeFenceFilter()
        return chunks.map { filter.feed($0) }.joined() + filter.flush()
    }

    @Test func dropsCodeFromTheStream() {
        let out = filter([reply])
        #expect(out.contains("Use this:"))
        #expect(out.contains("Then run it."))
        #expect(!out.contains("print"))
        #expect(!out.contains("```"))
    }

    @Test func everySplitPointGivesTheSameSpokenWords() {
        let expected = filter([reply]).split(whereSeparator: \.isWhitespace)
        let characters = Array(reply)
        for split in 0...characters.count {
            let out = filter([String(characters[..<split]), String(characters[split...])])
            #expect(out.split(whereSeparator: \.isWhitespace) == expected, "split at \(split)")
        }
    }

    @Test func proseWithoutCodePassesThroughPromptly() {
        var filter = CodeFenceFilter()
        #expect(filter.feed("Click the") == "Click the")
        #expect(filter.feed(" Share button.") == " Share button.")
    }
}
