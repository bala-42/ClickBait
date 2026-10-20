import Foundation

/// Screen-aware dictation (user's request, 2026-10-20): hold fn+⌃, speak, let go — the words
/// go into the focused text field. Words on screen (window title, nearby labels, the text
/// before the caret) are handed to Whisper as spelling hints, a short local-model pass tidies
/// the text in the app's style, and ClickBait pastes it (the one place it types; user's call).
/// Never into a password field; with no text field focused it's only copied.
///
///     let hints = Dictation.hints(windowTitle: "Atlas launch – Mail", labels: ["Send"], textBeforeCaret: "Hi Priya,")
///     // "Atlas, Priya. Hi Priya,"
///     Dictation.parseTidy(#"{"text": "See you at 3."}"#, raw: "see you at three")  // "See you at 3."
public enum Dictation {
    /// How the tidy-up writes for the app in front.
    public enum Style: String, Sendable {
        case casual, written, code, plain

        /// From the app's name: chat apps casual, mail and documents written, terminals and
        /// editors code, anything else plain.
        public init(app: String?) {
            let name = (app ?? "").lowercased()
            func any(_ words: [String]) -> Bool { words.contains { name.contains($0) } }
            if any(["messages", "slack", "discord", "whatsapp", "telegram", "signal", "teams", "messenger"]) { self = .casual }
            else if any(["mail", "outlook", "spark", "pages", "word", "notes", "textedit", "docs", "notion"]) { self = .written }
            else if any(["terminal", "iterm", "ghostty", "warp", "xcode", "code", "cursor", "zed", "sublime", "nova"]) { self = .code }
            else { self = .plain }
        }

        var instruction: String {
            switch self {
            case .casual: "a chat message: relaxed, short; no full stop needed at the end of a one-line message"
            case .written: "written text such as an email or a document: full sentences, proper punctuation"
            case .code: "a terminal or code editor: keep commands, names and symbols exactly, lowercase as spoken; no added full stop"
            case .plain: "normal sentences with punctuation"
            }
        }
    }

    /// Whisper's prompt, in characters (~100 tokens): long prompts slow it and can leak into the text.
    public static let maxHintCharacters = 400
    /// The text before the caret kept for the prompt (Whisper reads it as what came before).
    static let caretContext = 160
    static let maxHintWords = 30

    /// The pill when there's no field to paste into.
    public static let copiedNote = "transcribed · ⌘V to paste"

    /// Whisper's prompt: unusual words on screen (names, products, terms: capitalised
    /// mid-text, mixed case or with digits), then the text just before the caret.
    public static func hints(windowTitle: String?, labels: [String], textBeforeCaret: String?) -> String {
        var seen = Set<String>()
        var words: [String] = []
        for source in [windowTitle ?? ""] + labels + [textBeforeCaret ?? ""] {
            for raw in source.split(whereSeparator: { $0.isWhitespace || ",;!?()[]{}\"“”|–—/".contains($0) }) {
                let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'’-_*#.:"))
                guard word.count >= 3, word.count <= 30, isDistinctive(word),
                      !commonWords.contains(word.lowercased()), seen.insert(word.lowercased()).inserted else { continue }
                words.append(word)
            }
        }
        let tail = String((textBeforeCaret ?? "").suffix(caretContext)).trimmingCharacters(in: .whitespacesAndNewlines)
        var glossary = Array(words.prefix(maxHintWords))
        func prompt() -> String {
            [glossary.isEmpty ? "" : glossary.joined(separator: ", ") + ".", tail].filter { !$0.isEmpty }.joined(separator: " ")
        }
        while prompt().count > maxHintCharacters, !glossary.isEmpty { glossary.removeLast() }
        return String(prompt().suffix(maxHintCharacters))
    }

    /// A name or term worth spelling right: a capital letter, a digit, or caps inside.
    static func isDistinctive(_ word: String) -> Bool {
        guard let first = word.first, first.isLetter || first.isNumber else { return false }
        return first.isUppercase || word.contains(where: \.isNumber) || word.dropFirst().contains(where: \.isUppercase)
    }

    /// Menu and window words every app shows: no help spelling them.
    static let commonWords: Set<String> = [
        "the", "and", "for", "you", "your", "file", "edit", "view", "window", "help", "new", "open", "save", "close",
        "format", "insert", "tools", "go", "history", "bookmarks", "share", "send", "reply", "forward", "delete",
        "cancel", "done", "search", "settings", "untitled", "back", "next", "more", "show", "hide", "add", "remove",
        "copy", "paste", "undo", "redo", "select", "all", "find", "print", "today", "inbox", "this", "that", "with",
    ]

    /// How long the tidy-up may take before the raw text is used: 3 s, plus 1 s per 150
    /// characters heard (a long dictation takes longer to rewrite).
    public static func tidyLimit(for raw: String) -> Duration {
        .milliseconds(3_000 + raw.count * 1_000 / 150)
    }

    /// The tidied text, or `raw` when the reply is missing, malformed, empty, or doesn't look
    /// like the same words (much shorter or longer: the model answered it instead).
    public static func parseTidy(_ reply: String?, raw: String) -> String {
        guard let reply, let data = reply.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return raw }
        let ratio = Double(text.count) / Double(max(raw.count, 1))
        guard ratio >= 0.5 || raw.count - text.count < 12, ratio <= 1.5 || text.count - raw.count < 20 else { return raw }
        return text
    }

    /// The text as it should go in after `preceding` (the field's text before the caret): a
    /// space first when it would otherwise run into the previous word.
    public static func joined(_ text: String, after preceding: String?) -> String {
        guard let last = preceding?.last, !last.isWhitespace, !"([{\"'“‘/".contains(last),
              let first = text.first, !",.;:!?)]}".contains(first) else { return text }
        return " " + text
    }

    public enum Delivery: Equatable, Sendable {
        /// Pasted into the focused field.
        case paste
        /// Only copied ("transcribed · ⌘V to paste"): no text field, a password field, or the
        /// app in front changed while it was being written.
        case copyOnly
    }

    /// Paste only into an editable text field that isn't a password field.
    public static func delivery(role: String?, subrole: String?, editable: Bool, sameApp: Bool) -> Delivery {
        guard sameApp, editable, subrole != "AXSecureTextField", role != "AXSecureTextField" else { return .copyOnly }
        return .paste
    }
}
