/// A reply split into prose and fenced code blocks (```language … ```).
public enum MessageSegment: Equatable, Sendable {
    case text(String)
    case code(language: String?, code: String)
}

public enum MessageFormat {
    /// Splits a reply on ``` fences — wherever they appear, since models also write
    /// them mid-line ("…in a code block:```python") or around a single line. An
    /// unclosed fence (a reply still streaming in) runs to the end as code.
    public static func segments(_ text: String) -> [MessageSegment] {
        let parts = text.components(separatedBy: "```")
        var segments: [MessageSegment] = []
        for (index, part) in parts.enumerated() {
            if index.isMultiple(of: 2) {
                let prose = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty { segments.append(.text(prose)) }
            } else {
                let (language, code) = splitLanguage(part)
                if !code.isEmpty || index == parts.count - 1 { segments.append(.code(language: language, code: code)) }
            }
        }
        return segments
    }

    /// "python\nprint(1)\n" → ("python", "print(1)"). A first line counts as the language
    /// tag only when it's a single short word and code follows on later lines.
    private static func splitLanguage(_ part: String) -> (String?, String) {
        var body = Substring(part)
        var language: String?
        if let newline = body.firstIndex(of: "\n") {
            let firstLine = body[..<newline].trimmingCharacters(in: .whitespaces)
            if firstLine.isEmpty || (firstLine.count <= 20 && !firstLine.contains(" ")) {
                language = firstLine.isEmpty ? nil : firstLine
                body = body[body.index(after: newline)...]
            }
        }
        // Drop the blank lines around the code, keep its indentation.
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return (language, lines.joined(separator: "\n"))
    }

    /// The reply without its code blocks, for speaking.
    public static func spokenText(_ text: String) -> String {
        segments(text).compactMap { segment -> String? in
            if case .text(let prose) = segment { return prose }
            return nil
        }.joined(separator: " ")
    }
}

/// Streaming counterpart of `MessageFormat.spokenText`: feed reply text as it arrives,
/// get back only the prose (never code), even when a fence is split across chunks or
/// appears mid-line.
public struct CodeFenceFilter: Sendable {
    private var buffer = ""
    private var inCode = false

    public init() {}

    public mutating func feed(_ text: String) -> String {
        buffer += text
        var output = ""
        while let fence = buffer.range(of: "```") {
            if !inCode { output += buffer[..<fence.lowerBound] }
            inCode.toggle()
            if !inCode { output += " " }  // keep the sentences around a block apart
            buffer = String(buffer[fence.upperBound...])
        }
        // Up to two trailing backticks might be the start of a fence: hold them back.
        let held = buffer.reversed().prefix(while: { $0 == "`" }).count
        let keep = min(held, 2)
        let ready = buffer.dropLast(keep)
        if !inCode { output += ready }
        buffer = String(buffer.suffix(keep))
        return output
    }

    /// Whatever prose is left at the end of the stream.
    public mutating func flush() -> String {
        defer { buffer = "" }
        return inCode ? "" : buffer
    }
}
