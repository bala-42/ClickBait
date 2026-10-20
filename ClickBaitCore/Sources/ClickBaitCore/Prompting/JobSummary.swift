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

    /// The most a result pill says (user's rule, 2026-10-20: "I don't want that many words on
    /// my pills"): one line, ~6–8 words. The card has the whole answer.
    public static let headlineLength = 45

    /// The result pill's words: the answer's first sentence if it's short; else cut at a
    /// natural break (a comma, dash, colon, bracket) that leaves 25+ characters; else at
    /// a word, ending "…". "Done." when there are no words.
    public static func headline(from answer: String) -> String {
        // A pill is plain text: no markdown marks.
        let prose = CoordinateScrubber.scrub(MessageFormat.spokenText(answer)).text
            .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prose.isEmpty else { return "Done." }
        var splitter = SentenceSplitter()
        let first = (splitter.feed(prose).first ?? splitter.flush() ?? prose).trimmingCharacters(in: .whitespacesAndNewlines)
        guard first.count > headlineLength else { return first }
        // A break right after the limit still counts ("…twelve percent, mostly…").
        let window = String(first.prefix(headlineLength + 2))
        let breaks = [", ", " — ", " – ", " - ", ": ", "; ", " ("]
        if let cut = breaks.compactMap({ window.range(of: $0, options: .backwards)?.lowerBound })
            .filter({ window[..<$0].count <= headlineLength }).max(),
           window[..<cut].count >= 25 {  // "Andrew Friedman…" alone says nothing
            return String(window[..<cut]).trimmingCharacters(in: .whitespaces) + "…"
        }
        let prefix = first.prefix(headlineLength - 1)
        let wordBoundary = prefix.lastIndex(where: \.isWhitespace).map { prefix[..<$0] } ?? prefix
        return String(wordBoundary).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }

    /// The most a running card's live line shows (two lines at 12 pt in its 232 pt).
    public static let liveLength = 90

    /// The line a running card shows: the sentence the answer is writing now (the last one,
    /// finished or not), from its start, ending "…" if it's longer than `liveLength`.
    /// Before any words: "working on it…".
    /// `stage`: what the job is doing before its answer starts (`JobStage`), instead of the
    /// plain "working on it…" (C6, 2026-10-20).
    public static func liveLine(from speech: String, stage: JobStage? = nil) -> String {
        let prose = CoordinateScrubber.scrub(MessageFormat.spokenText(speech)).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prose.isEmpty else { return stage?.text ?? "working on it…" }
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
