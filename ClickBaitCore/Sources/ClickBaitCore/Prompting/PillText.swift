/// Whether a reply is short enough to be said in a pill (a few friendly words) instead of
/// the chat: "Yep, it's on!", "Saturday the 11th.", "Share's up here!". The chat is for
/// things worth reading — explanations, steps, code.
public enum PillText {
    /// About 3–6 words.
    public static let maxLength = 32

    public static func fits(_ text: String, code: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, code?.isEmpty ?? true, trimmed.count <= maxLength, !trimmed.contains("\n") else { return false }
        // One sentence: no full stop, "?" or "!" before the last character.
        let body = trimmed.dropLast()
        return !body.contains { $0 == "?" || $0 == "!" } && !body.contains(". ")
    }
}
