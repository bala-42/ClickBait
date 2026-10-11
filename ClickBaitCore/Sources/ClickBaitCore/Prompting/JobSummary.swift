import Foundation

/// A short, readable capsule label derived from a completed answer.
public enum JobSummary {
    public static let maxLength = 140

    public static func make(from answer: String) -> String {
        let prose = CoordinateScrubber.scrub(MessageFormat.spokenText(answer)).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prose.isEmpty else { return "Done." }

        var splitter = SentenceSplitter()
        var sentences = splitter.feed(prose)
        if let rest = splitter.flush(), !rest.isEmpty { sentences.append(rest) }
        let concise = sentences.prefix(2).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard concise.count > maxLength else { return concise }
        let prefix = concise.prefix(maxLength - 1)
        let wordBoundary = prefix.lastIndex(where: \.isWhitespace).map { prefix[..<$0] } ?? prefix
        return String(wordBoundary).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// The most a running card's live line shows (two lines at 12 pt in its 232 pt).
    public static let liveLength = 90

    /// The line a running card shows: the sentence the answer is writing now (the last one,
    /// finished or not), from its start, ending "…" if it's longer than `liveLength`.
    /// Before any words: "working on it…".
    public static func liveLine(from speech: String) -> String {
        let prose = CoordinateScrubber.scrub(MessageFormat.spokenText(speech)).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prose.isEmpty else { return "working on it…" }
        var splitter = SentenceSplitter()
        var sentences = splitter.feed(prose)
        if let rest = splitter.flush(), !rest.isEmpty { sentences.append(rest) }
        let current = (sentences.last ?? prose).trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.count > liveLength else { return current }
        let prefix = current.prefix(liveLength - 1)
        let wordBoundary = prefix.lastIndex(where: \.isWhitespace).map { prefix[..<$0] } ?? prefix
        return String(wordBoundary).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
