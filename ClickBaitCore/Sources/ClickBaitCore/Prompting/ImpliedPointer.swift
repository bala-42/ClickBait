/// The model sometimes answers a "where is…" question by naming the thing ("Click the
/// New Note button") without pointing at it. When the name is one of the listed
/// elements, the pointer can be taken from the list.
public enum ImpliedPointer {
    /// Questions that ask to be shown something on screen.
    static let locatingPhrases = [
        "where", "show me", "point", "find", "how do i", "how can i", "how to", "which button", "what do i click",
        "what should i click", "click", "open", "locate",
    ]

    public static func isLocating(_ question: String) -> Bool {
        let lower = question.lowercased()
        return locatingPhrases.contains { lower.contains($0) }
    }

    /// The listed element the answer names, if it's a locating question: names in quotes
    /// first ('New Note'), then the longest listed name found in the speech as whole words.
    public static func find(question: String, speech: String, elements: [PromptElement]) -> Pointer? {
        guard isLocating(question), !elements.isEmpty else { return nil }
        let text = " " + normalized(speech) + " "
        let candidates = elements.filter { normalized($0.label).count >= 3 }
        let quoted = quotedPhrases(in: speech).map(normalized)
        if let match = candidates.first(where: { quoted.contains(normalized($0.label)) }) {
            return Pointer(x: match.x, y: match.y, label: match.label)
        }
        let named = candidates
            .filter { text.contains(" " + normalized($0.label) + " ") }
            .max { normalized($0.label).count < normalized($1.label).count }
        return named.map { Pointer(x: $0.x, y: $0.y, label: $0.label) }
    }

    /// Lowercase words separated by single spaces, punctuation dropped.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func quotedPhrases(in text: String) -> [String] {
        var phrases: [String] = []
        for (open, close) in [("'", "'"), ("\"", "\""), ("“", "”"), ("‘", "’")] {
            var rest = Substring(text)
            while let start = rest.range(of: open), let end = rest[start.upperBound...].range(of: close) {
                phrases.append(String(rest[start.upperBound..<end.lowerBound]))
                rest = rest[end.upperBound...]
            }
        }
        return phrases
    }
}
