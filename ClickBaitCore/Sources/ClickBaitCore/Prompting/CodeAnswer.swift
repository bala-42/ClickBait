import Foundation

/// Code questions are answered in Markdown, then turned into ClickBait's answer JSON here.
/// Measured 2026-10-23 on gemma4:e4b (the main model): asked for a snake game in the JSON
/// answer it refused ("I cannot write a complete game in this interface") or, told to write
/// it, looped on tabs inside the JSON string; asked for Markdown it wrote all 173 lines in
/// ~10 s. Short fixes worked either way.
///
///     CodeAnswer.wanted(question: "write a snake game in Python", selectedText: nil)  // true
///     CodeAnswer.json(fromMarkdown: "Here it is.\n```python\nprint(1)\n```")
///     // {"speech": "Here it is.", "pointers": [], "code": "print(1)", "language": "python"}
public enum CodeAnswer {
    /// Asks for code, or asks about highlighted text that is code.
    public static func wanted(question: String, selectedText: String?) -> Bool {
        let words = " " + question.lowercased() + " "
        if let selectedText, looksLikeCode(selectedText) { return true }
        if codeWords.contains(where: words.contains) { return true }
        let makes = [" write ", " make ", " build ", " create ", " code "].contains(where: words.contains)
        return makes && [" game", " app ", " app?", " script", " program", " function", " website", " bot "].contains(where: words.contains)
    }

    private static let codeWords = [
        " code", " python", " swift", " javascript", " typescript", " java ", " kotlin", " c++", " c# ", " rust ",
        " golang", " ruby", " php", " sql", " regex", " html", " css", " bash", " shell script", " powershell",
        " function", " script", " snippet", " compile", " syntax error", " stack trace", " refactor", " debug",
    ]

    /// Brackets, operators or keywords that prose rarely has.
    public static func looksLikeCode(_ text: String) -> Bool {
        let markers = ["{", "}", "();", "()", " = ", "==", "=>", "->", "!)", "def ", "func ", "import ", "let ", "var ",
                       "const ", "print(", "return ", "#include", "</", "SELECT ", "for (", "for i in", "if (", "console."]
        return markers.filter(text.contains).count >= 2
    }

    public static let system = """
        You are ClickBait, a helper on the user's Mac; this request is about code. \
        Answer with one or two short plain sentences (no Markdown in them), then the code in \
        ONE fenced Markdown block that names its language, like ```python. The code is the \
        exact text to copy: complete and runnable, with no length limit — when asked for a \
        whole program (a game, a script, an app), write all of it; never say it can't be \
        written here. A fix gives the corrected code, not only the changed line. If the \
        user highlighted text, it is the code they mean. If no code is needed, just answer \
        in up to 4 short sentences with no block.
        """

    /// The reply as ClickBait's answer JSON: the sentences outside the block become
    /// "speech", the first block "code" and its tag "language". An unclosed block (the reply
    /// hit its cap) keeps what arrived.
    public static func json(fromMarkdown reply: String) -> String {
        var speech = reply
        var code: String?
        var language: String?
        if let open = reply.range(of: "```") {
            let afterOpen = reply[open.upperBound...]
            let tagEnd = afterOpen.firstIndex(of: "\n") ?? afterOpen.endIndex
            let tag = afterOpen[..<tagEnd].trimmingCharacters(in: .whitespaces)
            let bodyStart = tagEnd < afterOpen.endIndex ? afterOpen.index(after: tagEnd) : tagEnd
            let rest = reply[bodyStart...]
            let close = rest.range(of: "```")
            let body = rest[..<(close?.lowerBound ?? rest.endIndex)]
            code = String(body).trimmingCharacters(in: .newlines)
            language = tag.isEmpty ? nil : tag.lowercased()
            let after = close.map { String(rest[$0.upperBound...]) } ?? ""
            speech = String(reply[..<open.lowerBound]) + " " + after
        }
        speech = speech.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(":") ? $0.dropLast() + "." : $0 }  // "Here it is:" led into the block
            .joined(separator: " ")
        if speech.isEmpty { speech = code == nil ? "I couldn't come up with an answer." : "Here's the code." }
        var object: [String: Any] = ["speech": speech, "pointers": [Any]()]
        if let code, !code.isEmpty {
            object["code"] = code
            if let language { object["language"] = language }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
