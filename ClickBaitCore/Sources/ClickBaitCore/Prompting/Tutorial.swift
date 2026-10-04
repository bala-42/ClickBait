import Foundation

/// One step of a guided tutorial: what to click (as named on screen) and what to tell
/// the user.
public struct TutorialStep: Codable, Equatable, Sendable {
    /// The on-screen name of what to click ("File", "Export as PDF…", "Save").
    public var target: String
    /// A short instruction ("Open the File menu").
    public var instruction: String

    public init(target: String, instruction: String) {
        self.target = target
        self.instruction = instruction
    }
}

/// A how-to turned into steps to walk the user through on their own screen.
public struct TutorialPlan: Equatable, Sendable {
    /// One sentence saying what they'll do ("Here's how to export it as a PDF.").
    public var intro: String
    public var steps: [TutorialStep]
    /// The app the task has to be done in, when it isn't the one in front ("Safari"
    /// while in Notes). ClickBait opens it and plans the steps there.
    public var app: String?

    public static let maxSteps = 10

    public init(intro: String, steps: [TutorialStep], app: String? = nil) {
        self.intro = intro
        self.steps = steps
        self.app = app
    }

    /// More than one click: worth walking through. A single step is answered by pointing.
    public var isTutorial: Bool { steps.count >= 2 }

    /// The plan in a reply to `Prompt.tutorialSystem` (possibly with no steps: the
    /// intro then says why it can't be done here).
    public static func parse(_ raw: String) -> TutorialPlan? {
        guard let data = firstObject(in: raw)?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawSteps = object["steps"] as? [[String: Any]]
        else { return nil }
        let steps = rawSteps.compactMap { entry -> TutorialStep? in
            guard let target = (entry["target"] as? String).map(cleanTarget), !target.isEmpty else { return nil }
            let instruction = cleanInstruction(entry["instruction"] as? String ?? "")
            return TutorialStep(target: target, instruction: instruction.isEmpty ? "Click \(target)" : instruction)
        }
        let intro = cleanInstruction(object["speech"] as? String ?? "")
        // Padding a small model adds when it runs out of real steps: the same target
        // again (from anywhere earlier in the plan — a loop).
        var seen = Set<String>()
        let distinct = steps.filter { seen.insert($0.target.lowercased().replacingOccurrences(of: "...", with: "…")).inserted }
        let app = (object["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TutorialPlan(intro: intro, steps: Array(distinct.prefix(maxSteps)), app: (app?.isEmpty ?? true) ? nil : app)
    }

    /// A small model writes "Open the History menu and choose Clear History…" as one
    /// step. When a step opens a menu and the plan's words name an item that really is in
    /// that menu (`outline`: "History ▸ Clear History…"), the item becomes the next step.
    public func expandingMenus(using outline: [String]) -> TutorialPlan {
        guard !outline.isEmpty else { return self }
        let entries = outline.map { $0.components(separatedBy: " ▸ ") }.filter { $0.count >= 2 }
        let menus = Set(entries.map { $0[0].lowercased() })
        var expanded: [TutorialStep] = []
        for (index, step) in steps.enumerated() {
            expanded.append(step)
            guard menus.contains(step.target.lowercased()) else { continue }
            let next = index + 1 < steps.count ? steps[index + 1].target.lowercased() : nil
            let words = ImpliedPointer.normalized(step.instruction + " " + intro)
            // The longest item of this menu that the words mention.
            let item = entries
                .filter { $0[0].lowercased() == step.target.lowercased() }
                .map { $0[1] }
                .filter { ImpliedPointer.normalized($0).count >= 3 && words.contains(ImpliedPointer.normalized($0)) }
                .max { $0.count < $1.count }
            if let item, item.lowercased() != next {
                expanded.append(TutorialStep(target: item, instruction: "Choose \(item)"))
            }
        }
        var plan = self
        plan.steps = Array(expanded.prefix(Self.maxSteps))
        return plan
    }

    /// Separates "open that app" from the steps: a step whose target is an installed app
    /// other than the one in front becomes `app` (ClickBait opens it — green — and the
    /// lesson continues there); a step that "opens" the app already in front is dropped.
    /// The model rarely uses the "app" field and writes "Open Safari" as a step instead.
    public func separatingSetup(frontmostApp: String?, isInstalledApp: (String) -> Bool) -> TutorialPlan {
        var plan = self
        let front = frontmostApp?.lowercased()
        plan.steps = steps.filter { $0.target.lowercased() != front }
        if plan.app == nil, let first = plan.steps.first, isInstalledApp(first.target) {
            plan.app = first.target
            plan.steps.removeFirst()
        }
        if plan.app?.lowercased() == front { plan.app = nil }
        return plan
    }

    /// What's left after `done` steps, from a follow-up plan — or nil when that plan just
    /// starts the task over (its first step is one already done): the task is finished,
    /// and walking it again would e.g. clear another hour of history.
    public static func remaining(_ more: TutorialPlan, after done: [TutorialStep]) -> [TutorialStep]? {
        let doneTargets = Set(done.map { $0.target.lowercased() })
        guard let first = more.steps.first, !doneTargets.contains(first.target.lowercased()) else { return nil }
        let rest = more.steps.filter { !doneTargets.contains($0.target.lowercased()) }
        return rest.isEmpty ? nil : rest
    }

    /// What the lavender pill and the chat show: no positions or element-list leftovers.
    /// `Click button "Share" at (980, 52)` → `Click Share`.
    static func cleanInstruction(_ raw: String) -> String {
        var text = raw
        for pattern in [#"\s*\bat\s*\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)"#,  // at (980, 52)
                        #"\s*\(\s*(?:id|element)\s*:?\s*\d+\s*\)"#,                       // (id: 7)
                        #"\s*\b(?:element|id)\s+#?\d+\b"#] {                              // element 7
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = CoordinateScrubber.scrub(text).text
        // `button "Share"` / `menu item "Clear History…"` → the name alone.
        text = text.replacingOccurrences(
            of: #"\b(?:button|menu item|menu|pop-up menu|checkbox|radio button|text field|tab|link|row)\s+["“]([^"”]+)["”]"#,
            with: "$1", options: [.regularExpression, .caseInsensitive])
        return text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `button "New Note" at (300, 60)` → `New Note` (models copy element-list lines).
    static func cleanTarget(_ raw: String) -> String {
        var target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = target.firstIndex(where: { $0 == "\"" || $0 == "“" }),
           let close = target[target.index(after: open)...].firstIndex(where: { $0 == "\"" || $0 == "”" }) {
            target = String(target[target.index(after: open)..<close])
        }
        target = target.replacingOccurrences(of: #"\s*at\s*\(\s*\d+\s*,\s*\d+\s*\)"#, with: "", options: .regularExpression)
        for suffix in [" menu item", " menu", " button", " tab"] where target.lowercased().hasSuffix(suffix) && target.count > suffix.count + 1 {
            target = String(target.dropLast(suffix.count))
        }
        return target.trimmingCharacters(in: CharacterSet(charactersIn: "'\"“”‘’ ").union(.whitespaces))
    }

    private static func firstObject(in raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        return String(raw[start...end])
    }

    /// The steps as the chat shows them, with ticks for those done.
    public func checklist(done: Int) -> String {
        steps.enumerated().map { index, step in
            (index < done ? "✓ " : "\(index + 1). ") + step.instruction
        }.joined(separator: "\n")
    }
}

/// Questions that ask to be shown how to do something with more than one click.
public enum TutorialQuestion {
    static let phrases = ["how do i", "how can i", "how to", "how would i", "walk me through", "show me how", "teach me",
                          "guide me", "tutorial", "steps to", "what are the steps"]

    public static func asksForTutorial(_ question: String) -> Bool {
        let text = ImpliedPointer.normalized(question)
        return phrases.contains { text.hasPrefix($0) || text.contains(" " + $0) }
    }

    /// "Where's the refresh button?", "show me the refresh button", "point at Share":
    /// finding a thing (blue, one pointer) — not doing a task (lavender). "Show me how
    /// to…" is a task and is caught by `asksForTutorial` first.
    public static func isLocatingRequest(_ text: String) -> Bool {
        var words = ImpliedPointer.normalized(text).split(separator: " ").map(String.init)
        while let first = words.first, ["please", "can", "could", "you", "would", "will", "hey", "clickbait"].contains(first) {
            words.removeFirst()
        }
        let joined = words.joined(separator: " ")
        if joined.hasPrefix("show me how") || joined.hasPrefix("show me the steps") { return false }
        let starts = ["where", "wheres", "show me", "point", "find", "highlight", "locate", "which one is", "which is"]
        return starts.contains { joined == $0 || joined.hasPrefix($0 + " ") }
    }

    /// Orders for content, not clicks: "write me a poem", "summarise this", "explain
    /// that". They get a normal answer — never a tutorial.
    static let contentVerbs: Set<String> = ["write", "summarise", "summarize", "explain", "translate", "describe", "draft",
                                            "compose", "rewrite", "tell", "list", "define", "answer", "give", "suggest",
                                            "brainstorm", "proofread", "paraphrase", "outline", "calculate", "convert"]

    public static func isContentRequest(_ text: String) -> Bool {
        var words = ImpliedPointer.normalized(text).split(separator: " ").map(String.init)
        while let first = words.first, ["please", "can", "could", "you", "would", "will", "hey", "clickbait"].contains(first) {
            words.removeFirst()
        }
        return words.first.map(contentVerbs.contains) ?? false
    }

    /// An installed app the request names ("clear my Safari history" → "Safari"): the
    /// longest name found as whole words. `apps` are app names ("System Settings").
    public static func mentionedApp(in text: String, apps: [String]) -> String? {
        let spoken = " " + ImpliedPointer.normalized(text) + " "
        return apps
            .filter { ImpliedPointer.normalized($0).count >= 4 && spoken.contains(" " + ImpliedPointer.normalized($0) + " ") }
            .max { $0.count < $1.count }
    }
}

/// Finds a step's target among the clickable things Accessibility reports.
public enum StepMatcher {
    /// The best-named element for `target`: exact names first, then close ones; open
    /// menu items win ties (they're what the user is looking at mid-tutorial).
    public static func find(_ target: String, in elements: [ScreenElement], minimum: Double = 0.75) -> ScreenElement? {
        let scored = elements.map { element -> (ScreenElement, Double) in
            var score = LabelMatcher.similarity(target, element.label)
            if element.role == "AXMenuItem" { score += 0.01 }
            return (element, score)
        }
        return scored.filter { $0.1 >= minimum }.max { $0.1 < $1.1 }?.0
    }
}

/// The model's verdict on where the user is in a tutorial (`Prompt.progressSystem`).
public struct TutorialProgress: Equatable, Sendable {
    /// The step the user should do next, counting from 1.
    public var nextStep: Int
    public var done: Bool

    public static func parse(_ raw: String) -> TutorialProgress? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8))) as? [String: Any]
        else { return nil }
        let step = (object["next_step"] as? NSNumber)?.intValue ?? (object["next_step"] as? String).flatMap(Int.init) ?? 0
        let done = (object["done"] as? Bool) ?? false
        return TutorialProgress(nextStep: step, done: done)
    }
}

/// Trims an app's menu outline to what a question needs: every menu's title (so the
/// model knows where things live) plus the items sharing a word with the question.
/// 160 lines of Safari menus made planning slower without making it better.
public enum MenuOutline {
    public static func relevant(_ lines: [String], to question: String, limit: Int = 40) -> [String] {
        let words = Set(ImpliedPointer.normalized(question).split(separator: " ").filter { $0.count >= 4 }.map(String.init))
        var titles: [String] = []
        var matches: [String] = []
        for line in lines {
            let parts = line.components(separatedBy: " ▸ ")
            if let title = parts.first, !titles.contains(title) { titles.append(title) }
            let itemWords = Set(ImpliedPointer.normalized(parts.dropFirst().joined(separator: " ")).split(separator: " ").map(String.init))
            if !itemWords.isDisjoint(with: words) { matches.append(line) }
        }
        let shown = Set(matches.compactMap { $0.components(separatedBy: " ▸ ").first })
        return Array((matches + titles.filter { !shown.contains($0) }).prefix(limit))
    }
}

/// Whether Accessibility describes the app well enough to plan from text alone (no
/// screenshot): planning that way took ~1–2 s instead of ~10–13 s with the same steps.
public enum TutorialPlanning {
    public static func canUseTextOnly(elements: Int, menuItems: Int) -> Bool {
        elements >= 3 || menuItems >= 10
    }
}
