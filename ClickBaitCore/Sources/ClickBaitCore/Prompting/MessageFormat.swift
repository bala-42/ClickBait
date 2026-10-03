/// A reply split into prose and fenced code blocks (```language … ```).
public enum MessageSegment: Equatable, Sendable {
    case text(String)
    case code(language: String?, code: String)
}

public enum MessageFormat {
    /// Splits a reply on ``` fences. An unclosed fence (a reply still streaming in)
    /// runs to the end as code.
    public static func segments(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?
        var inCode = false

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { segments.append(.text(joined)) }
            prose = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    segments.append(.code(language: language, code: code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    flushProse()
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode {
            segments.append(.code(language: language, code: code.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return segments
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
/// get back only the prose (never code), even when a fence is split across chunks.
public struct CodeFenceFilter: Sendable {
    private var pendingLine = ""
    private var inCode = false

    public init() {}

    public mutating func feed(_ text: String) -> String {
        var output = ""
        var line = pendingLine + text
        pendingLine = ""

        while let newline = line.firstIndex(of: "\n") {
            let complete = String(line[..<newline])
            line = String(line[line.index(after: newline)...])
            if complete.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                if !inCode { output += " " }  // keep sentences after a block apart
                continue
            }
            if !inCode { output += complete + "\n" }
        }

        // An unfinished last line: hold it if it could still turn into a fence.
        let start = line.trimmingCharacters(in: .whitespaces)
        if inCode || (start.isEmpty && !line.isEmpty) || ("```".hasPrefix(start) || start.hasPrefix("```")) {
            pendingLine = line
        } else {
            output += line
        }
        return output
    }

    /// Whatever prose is left at the end of the stream.
    public mutating func flush() -> String {
        defer { pendingLine = "" }
        guard !inCode, !pendingLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { return "" }
        return pendingLine
    }
}
