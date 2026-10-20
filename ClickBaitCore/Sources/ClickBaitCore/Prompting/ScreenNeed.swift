import Foundation

/// Does a question need the screenshot? Reading it costs the local model ~7.5 s of its ~8.5 s
/// answer (qwen3.5:9b, 1280 px, 2026-10-20); a question about the world ("why is the sky
/// blue?") gets the same answer from text in ~1–2 s. Only clear cases go without: a plain
/// question that starts like one about the world and points at nothing. Anything else keeps
/// the screenshot, as before.
public enum ScreenNeed {
    /// How world questions start.
    static let worldOpeners = ["why", "what is", "what s", "whats", "what are", "what was", "what were",
                               "what does", "what do", "who", "when", "how many", "how much", "how far",
                               "how long", "how old", "how big", "how tall", "how does", "how do", "how are",
                               "how is", "define", "explain", "tell me about", "is", "are", "does", "do",
                               "can", "could", "should", "will", "would", "which is better", "convert",
                               "calculate", "translate", "give me", "name", "recommend", "suggest"]
    /// Words that point at the screen, the user's own things, or ask to be shown or walked through.
    static let screenWords: Set<String> = [
        "this", "that", "these", "those", "it", "its", "here", "there", "screen", "page", "window", "tab",
        "tabs", "app", "button", "menu", "icon", "click", "open", "see", "seeing", "showing", "shown", "show",
        "selected", "highlighted", "above", "below", "left", "right", "top", "bottom", "corner", "my", "mine",
        "me", "i", "file", "files", "document", "folder", "email", "emails", "message", "messages", "picture",
        "photo", "image", "video", "chart", "graph", "table", "error", "code", "line", "text", "word", "words",
        "setting", "settings", "toolbar", "sidebar", "field", "box", "link", "where", "point", "find",
    ]

    /// True only for a plain question about the world, with nothing selected, snipped or said before.
    public static func isAboutTheWorld(_ question: String, selectedText: String? = nil, snipped: Bool = false,
                                       followUp: Bool = false) -> Bool {
        guard !snipped, !followUp, (selectedText ?? "").isEmpty else { return false }
        let text = ImpliedPointer.normalized(question)
        guard !text.isEmpty, !ImpliedPointer.isLocating(question), !WebLookup.refersToScreen(question) else { return false }
        guard worldOpeners.contains(where: { text == $0 || text.hasPrefix($0 + " ") }) else { return false }
        // "how do I …" and "how to …" are walkthroughs in an app: they need the screen.
        if text.hasPrefix("how do i ") || text.hasPrefix("how to ") || text.hasPrefix("how can i ") { return false }
        return !text.split(separator: " ").contains { screenWords.contains(String($0)) }
    }
}
