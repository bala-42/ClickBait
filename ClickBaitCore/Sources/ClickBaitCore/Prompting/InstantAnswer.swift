import Foundation

/// Answers ClickBait can give without the model, because the screen already holds them —
/// only when there's no doubt (one exact match). Anything less goes to the model as before.
public enum InstantAnswer {
    // MARK: - Pointing ("where's the share button?")

    static let locatingOpeners = ["where is the", "where is", "wheres the", "wheres", "where s the", "where s",
                                  "show me the", "show me", "point at the", "point to the", "point at", "point to",
                                  "find the", "find", "locate the", "locate", "which is the", "highlight the"]
    static let thingWords: Set<String> = ["button", "menu", "icon", "tab", "field", "link", "option", "item", "box",
                                          "checkbox", "toggle", "switch", "on", "screen", "the", "here", "please"]

    /// The thing a locating question names ("where's the Share button?" → "share"), or nil.
    public static func locateTarget(in question: String) -> String? {
        let text = ImpliedPointer.normalized(question)
        guard TutorialQuestion.isLocatingRequest(question),
              let opener = locatingOpeners.first(where: { text.hasPrefix($0 + " ") }) else { return nil }
        var words = text.dropFirst(opener.count + 1).split(separator: " ").map(String.init)
        if words.first == "how" { return nil }  // "show me how to…" is a walkthrough
        while let last = words.last, thingWords.contains(last) { words.removeLast() }
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
