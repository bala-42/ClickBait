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

    public static let maxSteps = 10

    public init(intro: String, steps: [TutorialStep]) {
        self.intro = intro
        self.steps = steps
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
            let instruction = (entry["instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return TutorialStep(target: target, instruction: instruction.isEmpty ? "Click \(target)" : instruction)
        }
        let intro = (object["speech"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return TutorialPlan(intro: intro, steps: Array(steps.prefix(maxSteps)))
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
}

/// Finds a step's target among the clickable things Accessibility reports.
public enum StepMatcher {
    /// The best-named element for `target`: exact names first, then close ones; open
    /// menu items win ties (they're what the user is looking at mid-tutorial).
    public static func find(_ target: String, in elements: [ScreenElement]) -> ScreenElement? {
        let scored = elements.map { element -> (ScreenElement, Double) in
            var score = LabelMatcher.similarity(target, element.label)
            if element.role == "AXMenuItem" { score += 0.01 }
            return (element, score)
        }
        return scored.filter { $0.1 >= 0.75 }.max { $0.1 < $1.1 }?.0
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
