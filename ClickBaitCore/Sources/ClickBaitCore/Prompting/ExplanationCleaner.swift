/// Removes the lead-in models put on explanations despite being told not to:
/// "The highlighted text refers to amortization, which…" → "Amortization, which…".
public enum ExplanationCleaner {
    private static let subjects = [
        "the highlighted text", "the selected text", "this highlighted text", "this selected text", "the highlighted passage",
        "the selected passage", "the highlighted phrase", "the selected phrase", "the highlighted word", "the selected word",
        "the highlighted sentence", "the selected sentence", "this text", "this passage", "this phrase", "the text you highlighted",
        "the text you selected", "what you highlighted", "what you selected",
        // Snips (hold ⌥⌘): the close-up has the user's circle or box drawn on it.
        "the circled area", "the circled part", "the circled section", "the boxed area", "the boxed section",
        "the outlined area", "the highlighted area", "the area circled in red", "the area outlined in red",
        "the red outline", "the area inside the red outline", "the content inside the red outline",
        "what you circled", "the image", "this image", "the screenshot", "this screenshot",
    ]
    /// Verbs after which the rest of the sentence still reads naturally on its own.
    private static let verbs = [
        "refers to", "is referring to", "is about", "talks about", "describes", "explains", "discusses", "means",
        "is saying that", "says that", "states that", "suggests that", "indicates that", "is talking about",
        "shows", "contains", "displays", "highlights", "marks", "surrounds",
    ]

    public static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for subject in subjects {
            for verb in verbs {
                let leadIn = subject + " " + verb + " "
                if lower.hasPrefix(leadIn) {
                    return capitalizeFirst(String(trimmed.dropFirst(leadIn.count)))
                }
            }
        }
        return trimmed
    }

    private static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
