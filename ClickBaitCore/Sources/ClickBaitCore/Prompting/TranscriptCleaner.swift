/// Turns raw Whisper output into the user's question.
///
/// Whisper labels non-speech instead of returning nothing: `[BLANK_AUDIO]`,
/// `(wind blowing)`, `[Music]`, `*sigh*`, `♪`. Those must never reach the LLM as a
/// question, so they are stripped; an empty result means "nothing was said".
public enum TranscriptCleaner {
    public static func clean(_ raw: String) -> String {
        var text = ""
        var closer: Character?
        for character in raw {
            if let expected = closer {
                if character == expected { closer = nil }
                continue
            }
            switch character {
            case "[": closer = "]"
            case "(": closer = ")"
            case "*": closer = "*"
            case "♪", "♫": continue
            default: text.append(character)
            }
        }
        let words = text.split(whereSeparator: \.isWhitespace)
        let joined = words.joined(separator: " ")
        // Leftover punctuation alone ("...", "-") isn't speech either.
        return joined.contains(where: \.isLetter) || joined.contains(where: \.isNumber) ? joined : ""
    }
}
