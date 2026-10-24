import Foundation

/// Answers ClickBait can give without the model, because the screen already holds them —
/// only when there's no doubt (one exact match). Anything less goes to the model as before.
public enum InstantAnswer {
    // MARK: - Pointing ("where's the share button?")

    static let locatingOpeners = ["where is the", "where is", "wheres the", "wheres", "where s the", "where s",
                                  "where are the", "where are", "where re the",
                                  "show me where the", "show me where", "tell me where the", "tell me where",
                                  "show me the", "show me", "point at the", "point to the", "point at", "point to",
                                  "find the", "find", "locate the", "locate", "which is the", "highlight the"]
    static let thingWords: Set<String> = ["button", "buttons", "menu", "menus", "icon", "icons", "tab", "tabs", "field",
                                          "fields", "link", "links", "option", "options", "item", "items", "box", "boxes",
                                          "checkbox", "toggle", "switch", "on", "screen", "the", "here", "please"]
    /// "… are", "… is located": the end of "show me where the X is", not part of the name.
    static let trailingWords: Set<String> = ["is", "are", "located", "at"]
    /// Polite starts before the opener ("can you show me where…").
    static let politeLeads = ["can you", "could you", "please"]

    /// The things a locating question names: "where are the back and forward buttons?" →
    /// ["back", "forward"]. Empty when it isn't one.
    public static func locateTargets(in question: String) -> [String] {
        guard let whole = locateTarget(in: question) else { return [] }
        let parts = whole.components(separatedBy: " and ").map {
            $0.split(separator: " ").filter { !thingWords.contains(String($0)) }.joined(separator: " ")
        }
        return parts.contains(where: \.isEmpty) || parts.count > 3 ? [] : parts
    }

    /// The thing a locating question names ("where's the Share button?" → "share"), or nil.
    public static func locateTarget(in question: String) -> String? {
        var text = ImpliedPointer.normalized(question)
        for lead in politeLeads where text.hasPrefix(lead + " ") { text = String(text.dropFirst(lead.count + 1)) }
        guard TutorialQuestion.isLocatingRequest(question),
              let opener = locatingOpeners.first(where: { text.hasPrefix($0 + " ") }) else { return nil }
        var words = text.dropFirst(opener.count + 1).split(separator: " ").map(String.init)
        if words.first == "how" { return nil }  // "show me how to…" is a walkthrough
        // "… in Safari", "… on the toolbar", "… at the top": where to look, not the name.
        if let cut = words.lastIndex(where: { ["in", "on", "at"].contains($0) }), cut > 0, (2...4).contains(words.count - cut) {
            words = Array(words[..<cut])
        }
        while let last = words.last, thingWords.contains(last) || trailingWords.contains(last) { words.removeLast() }
        let target = words.joined(separator: " ")
        return target.isEmpty || words.count > 5 ? nil : target
    }

    /// The one element named exactly `target`; nil when there's none, or more than one
    /// that differ in place (two "Share" buttons: ask the model).
    public static func uniqueElement(named target: String, in elements: [ScreenElement]) -> ScreenElement? {
        let wanted = LabelMatcher.sameSpelling(ImpliedPointer.normalized(target))
        let matches = elements.filter { LabelMatcher.sameSpelling(ImpliedPointer.normalized($0.label)) == wanted }
        guard let first = matches.first else { return nil }
        let samePlace = matches.allSatisfy { abs($0.frame.x - first.frame.x) < 4 && abs($0.frame.y - first.frame.y) < 4 }
        return samePlace ? first : nil
    }

    /// No exact name, but one element clearly fits: every word of the target is in its
    /// name ("sidebar" → "Show Sidebar") and no other element's name has them all.
    public static func closeElement(named target: String, in elements: [ScreenElement]) -> ScreenElement? {
        let words = Set(LabelMatcher.sameSpelling(ImpliedPointer.normalized(target)).split(separator: " ").map(String.init))
        guard !words.isEmpty, words.allSatisfy({ $0.count >= 3 }) else { return nil }
        let matches = elements.filter { element in
            let name = Set(LabelMatcher.sameSpelling(ImpliedPointer.normalized(element.label)).split(separator: " ").map(String.init))
            return words.isSubset(of: name) && name.count <= words.count + 2
        }
        guard let first = matches.first else { return nil }
        let samePlace = matches.allSatisfy { abs($0.frame.x - first.frame.x) < 4 && abs($0.frame.y - first.frame.y) < 4 }
        return samePlace ? first : nil
    }

    // MARK: - Content, not controls

    static let months: Set<String> = ["january", "february", "march", "april", "june", "july", "august", "september",
                                      "october", "november", "december", "jan", "feb", "apr", "jun", "jul", "aug",
                                      "sep", "sept", "oct", "nov", "dec"]
    static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    static let contentWords: Set<String> = ["date", "dates", "event", "events", "meeting", "meetings", "appointment",
                                            "appointments", "birthday", "birthdays", "holiday", "deadline"]

    /// Asks for something *in* the app's content — a date, a day, an event — rather than one
    /// of its controls: "point to October 27th", "today's date", "Friday", "my 3pm meeting".
    /// Those are rarely in the element list (Calendar's days aren't clickable elements), and
    /// a pick from it lands on the nearest button ("Today", "View"): read the screenshot.
    public static func namesContent(_ question: String) -> Bool {
        let words = ImpliedPointer.normalized(question).split(separator: " ").map(String.init)
        return words.contains { word in
            months.contains(word) || weekdays.contains(word) || contentWords.contains(word)
                || word.contains(where: \.isNumber)
                || (word == "may" && words.contains { $0.contains(where: \.isNumber) })
        }
    }

    /// Words that name the same control ("settings" is often a gear called "Preferences").
    static let synonyms: [[String]] = [
        ["settings", "setting", "preferences", "preference", "options", "gear", "configure"],
        ["back", "previous", "prev", "backward"], ["forward", "next"], ["reload", "refresh"],
        ["new", "add", "plus", "create", "compose", "write"], ["delete", "trash", "bin", "remove", "discard"],
        ["close", "dismiss", "exit", "x"], ["search", "find", "lookup", "filter"], ["share", "export", "send"],
        ["menu", "more", "options", "ellipsis", "actions"], ["sidebar", "panel", "pane", "drawer"],
        ["account", "profile", "avatar", "user", "me"], ["home", "start"], ["play", "pause", "resume"],
        ["volume", "sound", "mute", "unmute", "audio"], ["download", "save"], ["edit", "rename", "pencil"],
        ["help", "support", "question"], ["notifications", "notification", "bell", "alerts"],
        ["fullscreen", "full", "maximize", "zoom", "expand"], ["minimize", "collapse", "shrink"],
        ["upload", "attach", "attachment", "paperclip"], ["message", "chat", "comment", "reply"],
        ["copy", "duplicate"], ["print", "printer"], ["calendar", "schedule"], ["today", "now"],
    ]

    /// Whether a picked element plausibly is the thing asked for: one of the target's words
    /// (or a synonym) is in its name. "October 27" → "Today" and "today's date" → "View"
    /// don't; "settings" → "Preferences" and "back" → "Go Back" do.
    /// "Where do I type?": answered from the focused element's text caret, exactly and with
    /// no model (`AXInspector.caretRect`). Measured 2026-10-14 in Terminal running Claude
    /// Code: the caret sat on the `❯` prompt line, while the 9B model pointed mid-screen and
    /// the snap accepted it inside the whole-window text area. Short questions only.
    public static func asksWhereToType(_ question: String) -> Bool {
        let text = ImpliedPointer.normalized(question)
        guard text.split(separator: " ").count <= unnamedPickMaxWords else { return false }
        let verbs = ["type", "write", "enter", "paste", "put my message", "put my text", "put text"]
        let asks = ["where do i ", "where can i ", "where should i ", "where to ", "where would i ", "where am i supposed to "]
        if asks.contains(where: { ask in verbs.contains { text.contains(ask + $0) } }) { return true }
        let fields = ["input", "input field", "input box", "text box", "text field", "message box", "prompt", "chat box", "typing area"]
        let whereIs = ["wheres the ", "where is the ", "where s the ", "show me the ", "point to the ", "find the "]
        return whereIs.contains { opener in fields.contains { text.contains(opener + $0) } }
    }

    /// The longest spoken question that may take the quick list pick with no target named.
    public static let unnamedPickMaxWords = 20

    /// Whether a question that names no target may still have the model pick from the
    /// element list (~1.5 s) and be pointed at at once: a short "where / which / what do I
    /// click" question, not "show me how". Measured 2026-10-14: 92- and 245-character
    /// spoken rambles that merely contained "where" were pointed at "Split pane" and
    /// "Terminal" — any control the model settled on.
    public static func allowsUnnamedPick(_ question: String) -> Bool {
        allowsPointing(question) && !ImpliedPointer.normalized(question).hasPrefix("show me how")
    }

    /// Whether an answer may point at all (the model's pointers, or a control its words
    /// name): an explicit, short request for a place on screen — "where / which / show me /
    /// what do I click", ≤ 20 words. Voice alone never points: a spoken ramble that merely
    /// contains "where" got pointers on the menu bar (2026-10-14).
    public static func allowsPointing(_ question: String) -> Bool {
        let words = ImpliedPointer.normalized(question).split(separator: " ").count
        return words <= unnamedPickMaxWords && (ImpliedPointer.isLocating(question) || TutorialQuestion.isLocatingRequest(question))
    }

    /// An unnamed pick is kept only when the control it chose shares a word with the question
    /// ("where do I type my message?" → "Message"); otherwise the screenshot answers instead.
    public static func unnamedPick(_ label: String, fits question: String) -> Bool {
        let filler: Set<String> = ["where", "wheres", "which", "what", "do", "does", "i", "is", "it", "click", "tap", "press",
                                   "button", "find", "can", "how", "should", "you", "me", "show", "point", "in", "on", "here"]
        let stop: Set<String> = ["the", "my", "a", "an", "of", "to", "s", "this", "that", "for", "with"]
        let words = ImpliedPointer.normalized(question).split(separator: " ").map(String.init)
            .filter { !filler.contains($0) && !stop.contains($0) }
        let have = ImpliedPointer.normalized(label).split(separator: " ").map(String.init)
        // The words themselves, not synonyms: "reply" ~ "message" let the Messages menu in.
        return words.contains { word in
            have.contains { $0 == word || ($0.count >= 4 && word.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0))) }
        }
    }

    public static func pick(_ label: String, fits target: String) -> Bool {
        let stop: Set<String> = ["the", "my", "a", "an", "of", "to", "s", "this", "that", "for", "with"]
        let wanted = ImpliedPointer.normalized(target).split(separator: " ").map(String.init).filter { !stop.contains($0) }
        let have = ImpliedPointer.normalized(label).split(separator: " ").map(String.init)
        guard !wanted.isEmpty else { return true }
        guard !have.isEmpty else { return false }
        func same(_ a: String, _ b: String) -> Bool {
            a == b || (a.count >= 4 && b.count >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)))  // "refresh" / "refreshes"
        }
        return wanted.contains { word in
            let family = synonyms.filter { $0.contains(word) }.flatMap { $0 } + [word]
            return have.contains { name in family.contains { same($0, name) } }
        }
    }

    /// The element id in a reply to `Prompt.pickSystem` (0 or nothing: none fits).
    public static func pickedID(in reply: String) -> Int? {
        pickedIDs(in: reply).first
    }

    /// Every element id in a reply to `Prompt.pickSystem`, in order ({"ids": [3, 5]} for
    /// "back and forward"; {"id": N} also accepted). Empty: none fits.
    public static func pickedIDs(in reply: String) -> [Int] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any]
        else { return [] }
        let raw = (object["ids"] as? [NSNumber]) ?? (object["id"] as? NSNumber).map { [$0] } ?? []
        var seen = Set<Int>()
        return raw.map(\.intValue).filter { $0 > 0 && seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    // MARK: - Menu walkthroughs ("how do I clear my history?")

    static let taskOpeners = ["show me how to", "show me how do i", "how do i", "how can i", "how to", "how would i",
                              "walk me through how to", "walk me through", "teach me how to", "teach me to",
                              "help me", "i want to", "i d like to", "i would like to", "can you", "could you", "please"]
    static let filler: Set<String> = ["my", "the", "this", "a", "an", "all", "current", "please", "now", "here", "it"]

    /// What a how-to or order asks to do, as plain words ("clear history").
    public static func taskPhrase(in request: String, app: String? = nil) -> String {
        var text = ImpliedPointer.normalized(request)
        var stripped = true
        while stripped {
            stripped = false
            for opener in taskOpeners where text.hasPrefix(opener + " ") {
                text = String(text.dropFirst(opener.count + 1))
                stripped = true
            }
        }
        let appWords = Set(ImpliedPointer.normalized(app ?? "").split(separator: " ").map(String.init))
        return text.split(separator: " ").map(String.init)
            .filter { !filler.contains($0) && !appWords.contains($0) && !["in", "on"].contains($0) }
            .joined(separator: " ")
    }

    /// A walkthrough straight from the app's menus when the request names exactly one
    /// menu item ("clear history" → History ▸ Clear History…): open the menu, choose the
    /// item. Later steps (a dialog's button) are planned by the model once it's chosen.
    public static func menuPlan(for request: String, app: String?, outline: [String]) -> TutorialPlan? {
        let wanted = taskPhrase(in: request, app: app)
        guard !wanted.isEmpty else { return nil }
        let paths = outline.map { $0.components(separatedBy: " ▸ ") }.filter { $0.count >= 2 }
        let matches = paths.filter { ImpliedPointer.normalized($0.last!) == wanted }
        guard matches.count == 1, let path = matches.first else { return nil }
        var steps = [TutorialStep(target: path[0], instruction: "Open the \(path[0]) menu", app: app)]
        for middle in path.dropFirst().dropLast() { steps.append(TutorialStep(target: middle, instruction: "Open \(middle)", app: app)) }
        steps.append(TutorialStep(target: path.last!, instruction: "Choose \(path.last!)", app: app))
        return TutorialPlan(intro: "It's in the \(path[0]) menu.", steps: steps)
    }
}
