/// Splits streaming text into sentences so speech can start on the first one while
/// the rest is still arriving.
///
/// A sentence ends at `.`, `!`, `?` or `…` followed by whitespace — but not after common
/// abbreviations ("e.g.", "Dr.") or inside numbers ("3.5", "v2.1"), which only need
/// the following whitespace to be safe. Call `flush()` when the stream ends.
public struct SentenceSplitter: Sendable {
    private var buffer = ""

    static let abbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "st", "no", "approx", "fig", "cf", "inc", "ltd", "jr", "sr",
    ]

    public init() {}

    /// Adds text and returns any sentences it completed.
    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let end = firstSentenceEnd() {
            let sentence = buffer[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    /// Whatever is left once the stream has ended.
    public mutating func flush() -> String? {
        defer { buffer = "" }
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// Index just past a sentence-ending mark that is followed by whitespace.
    private func firstSentenceEnd() -> String.Index? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)
            if Self.isTerminator(character) {
                // Swallow runs like "?!" or "...", and closing quotes/brackets.
                var end = next
                while end < buffer.endIndex, Self.isTerminator(buffer[end]) || Self.isCloser(buffer[end]) {
                    end = buffer.index(after: end)
                }
                guard end < buffer.endIndex else { return nil }  // need to see what follows
                if buffer[end].isWhitespace, !endsWithAbbreviation(before: index, terminator: character) {
                    return end
                }
                index = end
                continue
            }
            index = next
        }
        return nil
    }

    private func endsWithAbbreviation(before index: String.Index, terminator: Character) -> Bool {
        guard terminator == "." else { return false }
        let head = buffer[..<index]
        let word = head.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == "\"" || $0 == "“" }).last.map(String.init) ?? ""
        let normalized = word.lowercased()
        if Self.abbreviations.contains(normalized) { return true }
        // Single initials like "J. Smith".
        return normalized.count == 1 && normalized.first?.isLetter == true && word.first?.isUppercase == true
    }

    private static func isTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character == "…"
    }

    private static func isCloser(_ character: Character) -> Bool {
        character == "\"" || character == "”" || character == "’" || character == ")" || character == "'"
    }
}
