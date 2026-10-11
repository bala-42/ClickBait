import Foundation

/// Removes the lead-in models put on explanations despite being told not to:
/// "The highlighted text refers to amortization, which…" → "Amortization, which…".
public enum ExplanationCleaner {
    /// Explanations are 2–4 sentences (the prompt's rule); a reply that runs on past that is
    /// cut there: one ran to 4,294 characters of sales talk about a stock diagram (2026-10-11).
    public static let maxSentences = 4

    /// The first `maxSentences` sentences of an explanation.
    public static func limited(_ text: String) -> String {
        var splitter = SentenceSplitter()
        var sentences = splitter.feed(text)
        if let rest = splitter.flush() { sentences.append(rest) }
        guard sentences.count > maxSentences else { return text }
        return sentences.prefix(maxSentences).joined(separator: " ")
    }

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

/// Takes positions out of an answer's text. A small model sometimes writes its parts
/// list — coordinates and all — into the explanation instead of the "parts" field;
/// the chat must never show "{"x": 400, …}" or "(400, 200)". What's pulled out becomes
/// the parts.
public enum CoordinateScrubber {
    public static func scrub(_ text: String) -> (text: String, parts: [Pointer]) {
        guard text.contains(where: \.isNumber) else { return (text, []) }  // nothing to take out
        var parts: [Pointer] = []
        var result = text
        // {"x": 400, "y": 200, "label": "Optic Chiasm"} (any key order, quotes optional)
        let object = #"\{[^{}]*?"?x"?\s*:\s*-?\d+(?:\.\d+)?[^{}]*?\}"#
        if let regex = try? NSRegularExpression(pattern: object) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let fragment = String(result[range])
                if let part = parse(fragment) { parts.insert(part, at: 0) }
                result.replaceSubrange(range, with: "")
            }
        }
        // "(x: 400, y: 200)", "(400, 200)", "at x=400, y=200"
        for pattern in [#"\s*\(\s*(?:x\s*[:=]\s*)?\d{1,4}\s*,\s*(?:y\s*[:=]\s*)?\d{1,4}\s*\)"#,
                        #"\s*(?:at\s+)?x\s*[:=]\s*\d{1,4}\s*,\s*y\s*[:=]\s*\d{1,4}"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // A "Parts:" heading left with nothing after it, and stray separators.
        result = result.replacingOccurrences(of: #"\s*Parts\s*:\s*[,.\s]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\s*,\s*(?=[,.]|$)"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // "…as follows:" left dangling only because its list was taken out.
        if result != text.trimmingCharacters(in: .whitespacesAndNewlines), result.hasSuffix(":") { result.removeLast() }
        return (result, parts)
    }

    /// For text still streaming in: everything before a coordinate list starts (a
    /// half-written `{"x": 4` can't be recognised yet), then scrubbed.
    public static func partial(_ text: String) -> String {
        var cut = text
        for marker in ["{\"", "{ \"", "Parts:", "parts:"] {
            if let range = cut.range(of: marker) { cut = String(cut[..<range.lowerBound]) }
        }
        return scrub(cut.trimmingCharacters(in: .whitespacesAndNewlines)).text
    }

    private static func parse(_ fragment: String) -> Pointer? {
        func number(_ key: String) -> Double? {
            guard let regex = try? NSRegularExpression(pattern: "\"?\(key)\"?\\s*:\\s*(-?\\d+(?:\\.\\d+)?)"),
                  let match = regex.firstMatch(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)),
                  let range = Range(match.range(at: 1), in: fragment) else { return nil }
            return Double(fragment[range])
        }
        guard let x = number("x"), let y = number("y"),
              let regex = try? NSRegularExpression(pattern: #""?label"?\s*:\s*"([^"]+)""#),
              let match = regex.firstMatch(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)),
              let range = Range(match.range(at: 1), in: fragment) else { return nil }
        return Pointer(x: x, y: y, label: String(fragment[range]))
    }
}
