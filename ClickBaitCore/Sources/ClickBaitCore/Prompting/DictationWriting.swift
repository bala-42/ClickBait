import Foundation

/// fn+⌃ writing (user's ask, 2026-10-25): the one hotkey that types also writes. What was said
/// is either words to type, as before, or a request ("reply to this email", "give it to me in
/// point form", anything said over a selection) that the local model carries out. Decided by
/// fixed rules on the words, never the model, and when in doubt the words are typed. "type …"
/// always types.
public enum DictationWriting {
    /// What the request works on.
    public enum Subject: String, Sendable, Equatable {
        /// The text selected when fn+⌃ was pressed: rewritten in its place.
        case selection
        /// What ClickBait wrote last, just now, in this field: replaced.
        case lastResult
        /// The draft in the field: rewritten in its place.
        case field
        /// Nothing to rework: written new at the caret, from what's on screen (the email it replies to).
        case screen
    }

    public enum Plan: Sendable, Equatable {
        case type(String)
        case write(instruction: String, subject: Subject)
    }

    /// Verbs that open a request.
    static let requestVerbs: Set = ["reply", "respond", "write", "draft", "compose", "rewrite", "rephrase", "summarise",
                                    "summarize", "translate", "shorten", "expand", "proofread", "paraphrase", "answer"]
    /// Verbs that are a request only with a reference ("make it shorter", not "make sure…").
    static let referringVerbs: Set = ["make", "turn", "put", "give", "convert", "change", "format", "fix", "list", "clean"]
    /// How it should look or sound ("in point form", "more formal").
    static let shapes = ["point form", "points", "bullet points", "bullets", "bulleted", "numbered list", "a list",
                         "a table", "one line", "one sentence", "shorter", "longer", "more formal", "less formal",
                         "formal", "friendlier", "more casual", "casual", "simpler", "more polite", "professional",
                         "in spanish", "in french", "in german", "in malay", "in chinese", "in mandarin", "in tamil",
                         "in japanese", "in korean", "in hindi", "in english", "in arabic", "in italian", "in portuguese"]
    /// Words that point back at something ("it", "this").
    static let references: Set = ["it", "this", "that", "these", "those", "them", "everything", "all"]

    public static func plan(heard: String, hasSelection: Bool, hasLastResult: Bool, fieldHasText: Bool) -> Plan {
        let words = ImpliedPointer.normalized(heard).split(separator: " ").map(String.init)
        guard let first = words.first else { return .type(heard) }
        // "type …": always the words, as said.
        if first == "type" {
            let rest = heard.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces)
            return .type(rest.isEmpty ? heard : rest)
        }
        if hasSelection { return .write(instruction: heard, subject: .selection) }
        let text = " " + words.joined(separator: " ") + " "
        let refers = words.contains { references.contains($0) }
        let shaped = shapes.contains { text.contains(" " + $0 + " ") }
        let request = requestVerbs.contains(first)
            || (referringVerbs.contains(first) && refers)
            || (shaped && refers)
        guard request else { return .type(heard) }
        // "it" is what was just written, else the draft here, else (nothing to rework) the screen.
        let reworks = refers || ["rewrite", "rephrase", "shorten", "expand", "proofread", "paraphrase", "summarise", "summarize"]
            .contains(first) && !text.contains(" email ") && !text.contains(" page ")
        let subject: Subject = reworks && hasLastResult ? .lastResult : reworks && fieldHasText ? .field : .screen
        return .write(instruction: heard, subject: subject)
    }

    /// The written text from the model's reply, or nil (nothing usable: never the raw request).
    public static func parse(_ reply: String?) -> String? {
        guard let reply, let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Text sent along is capped, so a long page doesn't swamp a small model.
    public static let maxSubject = 4_000
    public static let maxScreen = 3_000
}
