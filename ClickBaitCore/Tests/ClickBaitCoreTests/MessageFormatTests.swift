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

    @Test func tidiesMarkdownBlocksTheInlineRendererWouldShowRaw() {
        let raw = """
            ## Steps
            - open **Safari**
              * then History

            ---


            1. clear it
            a **stray bold
            """
        #expect(MessageFormat.tidyProse(raw) == """
            **Steps**
            • open **Safari**
                ◦ then History

            1. clear it
            a stray bold
            """)
        #expect(String(MessageFormat.attributedProse("# Hi").characters) == "Hi")
    }

    @Test func breaksALongParagraphIntoShortOnes() {
        let wall = "Safari keeps your history in one place. You can clear it from the History menu at the top of the screen. Pick Clear History, then choose how far back to go. All history removes everything. Your bookmarks stay where they are."
        let shown = MessageFormat.tidyProse(wall)
        #expect(shown.components(separatedBy: "\n\n").count == 3)
        #expect(shown.hasPrefix("Safari keeps your history in one place. You can clear it"))
        #expect(MessageFormat.tidyProse("Short answer. Two sentences only.") == "Short answer. Two sentences only.")
    }

    @Test func putsAnInlineListOnLines() {
        let inline = "To share a page in Safari you have a few options that work well together: 1. click the Share button in the toolbar 2. choose AirDrop, Messages or Mail from the menu 3. pick the person or device you want to send it to and confirm."
        let lines = MessageFormat.tidyProse(inline).components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines[1].hasPrefix("1. click") && lines[3].hasPrefix("3. pick"))
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

    @Test func fenceInTheMiddleOfALine() {
        // A real qwen2.5vl reply: the opening fence right after a colon, no newline.
        let reply = "Sure, here's the Python version in a code block format:```python\npython3 --version\nPython 3.9.6\n```"
        #expect(MessageFormat.segments(reply) == [
            .text("Sure, here's the Python version in a code block format:"),
            .code(language: "python", code: "python3 --version\nPython 3.9.6"),
        ])
    }

    @Test func singleLineFence() {
        #expect(MessageFormat.segments("Run ```ls -la``` then check.") == [
            .text("Run"), .code(language: nil, code: "ls -la"), .text("then check."),
        ])
    }

    @Test func emptyClosedBlocksAreDropped() {
        #expect(MessageFormat.segments("Hi ``` ``` there") == [.text("Hi"), .text("there")])
    }

    @Test func spokenTextSkipsCode() {
        #expect(MessageFormat.spokenText(reply) == "Use VLOOKUP like this: Then drag it down the column.")
    }
}

struct CodeFenceFilterTests {
    private let reply = "Use this:\n```python\nprint(\"hi\")\n```\nThen run it. Or format:```bash\necho hi\n``` done."

    private func filter(_ chunks: [String]) -> String {
        var filter = CodeFenceFilter()
        return chunks.map { filter.feed($0) }.joined() + filter.flush()
    }

    @Test func dropsCodeFromTheStream() {
        let out = filter([reply])
        #expect(out.contains("Use this:"))
        #expect(out.contains("Then run it."))
        #expect(out.contains("done."))
        #expect(!out.contains("print"))
        #expect(!out.contains("echo"))
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
