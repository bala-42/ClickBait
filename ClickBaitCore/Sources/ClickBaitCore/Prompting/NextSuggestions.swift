import Foundation

/// "suggested next:" on a finished background answer's card: the local model's follow-ups
/// (`Prompt.nextSystem`), kept short and distinct.
public enum NextSuggestions {
    public static let maxCount = 2
    /// A pill is 20 pt tall in a 260 pt card: longer ones are dropped, not cut.
    public static let maxLength = 40

    /// The suggestions in a `{"next": [...]}` reply: trimmed, at most `maxCount`, none empty,
    /// too long, repeated, or the question itself. Nil for a reply that isn't one.
    public static func parse(_ reply: String, question: String) -> [String]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let next = object["next"] as? [Any] else { return nil }
        var seen: Set<String> = [normalized(question)]
        var kept: [String] = []
        for case let item as String in next {
            let text = item.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
            let key = normalized(text)
            guard !text.isEmpty, text.count <= maxLength, !seen.contains(key) else { continue }
            seen.insert(key)
            kept.append(text.prefix(1).uppercased() + text.dropFirst())
            if kept.count == maxCount { break }
        }
        return kept
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
