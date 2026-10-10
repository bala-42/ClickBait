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
}
