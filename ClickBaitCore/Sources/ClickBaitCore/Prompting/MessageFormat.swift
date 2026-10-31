import Foundation

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

    /// A prose segment as it should read in a chat bubble or a dock card: markdown blocks the
    /// inline-only renderer would show raw become tidy lines. "# Heading" → **Heading**,
    /// "- item"/"* item" → "• item" (nested → "◦"), "---" rules dropped, runs of blank lines
    /// cut to one, and a stray unclosed "**" removed. Inline markdown (bold, `code`, links)
    /// is left for the renderer.
    public static func tidyProse(_ prose: String) -> String {
        var out: [String] = []
        for raw in breakUp(prose).components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if out.last?.isEmpty == false { out.append("") }
                continue
            }
            if line.count >= 3, line.allSatisfy({ "-*_".contains($0) }) { continue }  // a horizontal rule
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if title.isEmpty { continue }
                line = "**\(title.replacingOccurrences(of: "**", with: ""))**"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                line = (indent >= 2 ? "    ◦ " : "• ") + line.dropFirst(2)
            }
            if line.components(separatedBy: "**").count.isMultiple(of: 2) { line = line.replacingOccurrences(of: "**", with: "") }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// Answers mostly come as one long spoken-style paragraph (user's report, 2026-11-01): a
    /// paragraph over ~180 characters (3+ sentences) is shown in short ones, two sentences each, and a list
    /// written inline ("1. … 2. … 3. …") gets a line per item. Only how it's shown changes.
    static func breakUp(_ prose: String) -> String {
        prose.components(separatedBy: "\n").map { paragraph -> String in
            let line = paragraph.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("- "), !line.hasPrefix("* "), !line.hasPrefix("|") else { return paragraph }
            // An inline numbered list, any length: each item on its own line, the lead-in above it.
            let marker = /\s(?=(?:\d{1,2}[.)]|\(\d{1,2}\))\s+\S)/
            if line.count > 60, line.matches(of: marker).count >= 2 { return line.replacing(marker, with: { _ in "\n" }) }
            guard line.count > 180 else { return paragraph }
            var splitter = SentenceSplitter()
            var sentences = splitter.feed(line)
            if let rest = splitter.flush(), !rest.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(rest) }
            guard sentences.count >= 3 else { return paragraph }
            var chunks: [String] = [], current: [String] = []
            for sentence in sentences {
                current.append(sentence.trimmingCharacters(in: .whitespaces))
                if current.count == 2 { chunks.append(current.joined(separator: " ")); current = [] }
            }
            if !current.isEmpty { chunks.append(current.joined(separator: " ")) }
            return chunks.joined(separator: "\n\n")
        }.joined(separator: "\n")
    }

    /// A prose segment ready for SwiftUI `Text`: tidied blocks, inline markdown, line breaks kept.
    public static func attributedProse(_ prose: String) -> AttributedString {
        let tidy = tidyProse(prose)
        return (try? AttributedString(markdown: tidy, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(tidy)
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
