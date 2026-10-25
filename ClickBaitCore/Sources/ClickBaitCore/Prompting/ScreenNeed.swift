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
                               "calculate", "translate", "give me", "name", "recommend", "suggest", "about"]
    /// What people say before the question itself ("hey, can you tell me who…"): left out
    /// before looking at how it starts (user's "who is Steve Jobs" was sent with the screen,
    /// and the model said it couldn't tell, 2026-10-24).
    static let leadIns = ["hey", "hi", "clickbait", "ok", "okay", "so", "um", "please", "can you", "could you",
                          "would you", "do you know", "tell me", "i want to know", "i d like to know", "i wonder",
                          "quick question", "just"]
    /// Pronouns that lean on what was said before: a follow-up with one needs the conversation's screen.
    static let backReferences: Set<String> = ["he", "she", "they", "him", "her", "them", "his", "hers", "their", "theirs"]

    /// The question without its lead-ins.
    public static func withoutLeadIns(_ text: String) -> String {
        var rest = text
        var changed = true
        while changed {
            changed = false
            for lead in leadIns where rest == lead || rest.hasPrefix(lead + " ") {
                rest = String(rest.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return rest
    }
    /// Words that point at the screen, the user's own things, or ask to be shown or walked through.
    static let screenWords: Set<String> = [
        "this", "that", "these", "those", "it", "its", "here", "there", "screen", "page", "window", "tab",
        "tabs", "app", "button", "menu", "icon", "click", "open", "see", "seeing", "showing", "shown", "show",
        "selected", "highlighted", "above", "below", "left", "right", "top", "bottom", "corner", "my", "mine",
        "me", "i", "file", "files", "document", "folder", "email", "emails", "message", "messages", "picture",
        "photo", "image", "video", "chart", "graph", "table", "error", "code", "line", "text", "word", "words",
        "setting", "settings", "toolbar", "sidebar", "field", "box", "link", "where", "point", "find",
    ]

    /// A follow-up in a conversation that wasn't about the screen ("who is Steve Jobs?" →
    /// "elaborate") stays off it unless it names the screen: given a screenshot, "elaborate"
    /// described System Settings instead (user's report, 2026-10-25). "This" and "that"
    /// don't count here: in a follow-up they mean the last answer.
    public static func followUpNeedsScreen(_ question: String) -> Bool {
        if ImpliedPointer.isLocating(question) { return true }
        let words = Set(ImpliedPointer.normalized(question).split(separator: " ").map(String.init))
        return !words.isDisjoint(with: followUpScreenWords)
            || ImpliedPointer.normalized(question).contains("on my screen") || ImpliedPointer.normalized(question).contains("on screen")
    }

    /// "tell me more", "elaborate", "go on": about the last answer, never the screen. Given a
    /// screenshot, "tell me more" about a palindrome function described a weather widget
    /// (test drive, 2026-10-25).
    public static func asksForMore(_ question: String) -> Bool {
        let text = ImpliedPointer.normalized(question)
        return moreAsks.contains { text == $0 || text.hasPrefix($0 + " ") || text.hasSuffix(" " + $0) || text.contains(" " + $0 + " ") }
    }

    static let moreAsks = ["tell me more", "more", "elaborate", "go on", "continue", "keep going", "expand", "expand on that",
                           "explain more", "explain further", "more detail", "more details", "in more detail", "say more", "go deeper"]

    static let followUpScreenWords: Set<String> = [
        "screen", "window", "windows", "page", "tab", "tabs", "app", "button", "buttons", "menu", "click", "here",
        "highlighted", "selected", "selection", "see", "showing", "shown", "open", "visible", "look", "icon", "toolbar",
        "sidebar", "field", "error", "pointer", "cursor", "display",
    ]

    /// True only for a plain question about the world, with nothing selected, snipped or said before.
    public static func isAboutTheWorld(_ question: String, selectedText: String? = nil, snipped: Bool = false,
                                       followUp: Bool = false) -> Bool {
        guard !snipped, (selectedText ?? "").isEmpty else { return false }
        let text = withoutLeadIns(ImpliedPointer.normalized(question))
        guard !text.isEmpty, !ImpliedPointer.isLocating(question), !WebLookup.refersToScreen(question) else { return false }
        // A follow-up stands alone only when it names its own subject ("who is he?" leans on the last answer).
        if followUp, text.split(separator: " ").contains(where: { backReferences.contains(String($0)) }) { return false }
        guard worldOpeners.contains(where: { text == $0 || text.hasPrefix($0 + " ") }) else { return false }
        // "how do I …" and "how to …" are walkthroughs in an app: they need the screen.
        if text.hasPrefix("how do i ") || text.hasPrefix("how to ") || text.hasPrefix("how can i ") { return false }
        return !text.split(separator: " ").contains { screenWords.contains(String($0)) }
    }
}
