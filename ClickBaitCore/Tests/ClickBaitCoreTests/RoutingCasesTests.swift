import Testing
@testable import ClickBaitCore

/// How ClickBait's rules sort the labelled questions (`RoutingCases`) before any model is asked:
/// "where" → point, how-to → walkthrough, order-shaped → action, else an answer. The real path
/// then asks the model in some cases (an order is checked, a how-to about content is sorted),
/// so this measures the first gate only. It fails if accuracy drops below today's.
struct RoutingCasesTests {
    static func rules(_ question: String) -> IntentRouter.Intent {
        if TutorialQuestion.asksWhere(question) || (TutorialQuestion.isLocatingRequest(question) && !TutorialQuestion.asksForTutorial(question)) {
            return .point
        }
        if TutorialQuestion.asksForTutorial(question) { return .tutorial }
        if CommandParser.looksLikeOrder(question), !TutorialQuestion.isContentRequest(question) { return .order }
        return .answer
    }

    @Test func rulesSortTheLabelledQuestions() {
        var right = 0
        var wrong: [String] = []
        for item in RoutingCases.all {
            let got = Self.rules(item.question)
            if got == item.expected { right += 1 } else { wrong.append("\"\(item.question)\": \(item.expected) → \(got)") }
        }
        let accuracy = Double(right) / Double(RoutingCases.all.count)
        print("Routing rules: \(right)/\(RoutingCases.all.count) (\(Int(accuracy * 100))%)")
        for line in wrong { print("  wrong: \(line)") }
        #expect(accuracy >= Self.baseline, "rules accuracy fell to \(Int(accuracy * 100))%")
    }

    /// Today's accuracy (2026-10-24: 48 of 50; misses "which button closes this window", read
    /// as an answer, and "how do I make this code faster", a how-to the model's sort catches).
    /// Raise it as the rules improve.
    static let baseline = 0.98  // 50 of 51 (2026-10-24: "show me how to" a walkthrough, "which button…" points)
}
