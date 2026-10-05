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
        let wanted = ImpliedPointer.normalized(target)
        let matches = elements.filter { ImpliedPointer.normalized($0.label) == wanted }
        guard let first = matches.first else { return nil }
        let samePlace = matches.allSatisfy { abs($0.frame.x - first.frame.x) < 4 && abs($0.frame.y - first.frame.y) < 4 }
        return samePlace ? first : nil
    }

    /// No exact name, but one element clearly fits: every word of the target is in its
    /// name ("sidebar" → "Show Sidebar") and no other element's name has them all.
    public static func closeElement(named target: String, in elements: [ScreenElement]) -> ScreenElement? {
        let words = Set(ImpliedPointer.normalized(target).split(separator: " ").map(String.init))
        guard !words.isEmpty, words.allSatisfy({ $0.count >= 3 }) else { return nil }
        let matches = elements.filter { element in
            let name = Set(ImpliedPointer.normalized(element.label).split(separator: " ").map(String.init))
            return words.isSubset(of: name) && name.count <= words.count + 2
        }
        guard let first = matches.first else { return nil }
        let samePlace = matches.allSatisfy { abs($0.frame.x - first.frame.x) < 4 && abs($0.frame.y - first.frame.y) < 4 }
        return samePlace ? first : nil
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
