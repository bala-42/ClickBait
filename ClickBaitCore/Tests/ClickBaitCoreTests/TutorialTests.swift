import Foundation
import Testing
@testable import ClickBaitCore

struct TutorialTests {
    @Test func parsesAPlan() {
        let raw = #"{"speech": "Here's how to export it as a PDF.", "steps": [{"target": "File", "instruction": "Open the File menu"}, {"target": "Export as PDF…", "instruction": "Choose Export as PDF…"}, {"target": "Save", "instruction": "Click Save"}]}"#
        let plan = TutorialPlan.parse(raw)
        #expect(plan?.steps.map(\.target) == ["File", "Export as PDF…", "Save"])
        #expect(plan?.checklist(done: 1) == "✓ Open the File menu\n2. Choose Export as PDF…\n3. Click Save")
        #expect(plan?.isTutorial == true)
        #expect(TutorialPlan.parse(#"{"speech": "Just click Share.", "steps": [{"target": "Share", "instruction": "Click Share"}]}"#)?.isTutorial == false)
        #expect(TutorialPlan.parse(#"{"speech": "Can't here.", "steps": []}"#)?.steps.isEmpty == true)
        // Real qwen2.5vl:7b target, copied from the element list.
        #expect(TutorialPlan.parse(#"{"speech": "s", "steps": [{"target": "button \"New Note\" at (300, 60)", "instruction": "Click New Note"}]}"#)?.steps.first?.target == "New Note")
        #expect(TutorialPlan.cleanTarget("File menu") == "File")
        #expect(TutorialPlan.cleanTarget("'Show Path Bar'") == "Show Path Bar")
    }

    @Test(arguments: [
        ("How do I export this as a PDF?", true), ("walk me through sharing this", true), ("Show me how to add a column", true),
        ("Where is the share button?", false), ("What is a PDF?", false), ("Export this as a PDF", false),
    ])
    func spotsTutorialQuestions(_ question: String, _ expected: Bool) {
        #expect(TutorialQuestion.asksForTutorial(question) == expected)
    }

    @Test func findsAStepsTarget() {
        let elements = [
            ScreenElement(role: "AXMenuBarItem", label: "File", frame: Rect(x: 60, y: 0, width: 40, height: 24)),
            ScreenElement(role: "AXMenuItem", label: "Export as PDF…", frame: Rect(x: 70, y: 200, width: 200, height: 22)),
            ScreenElement(role: "AXButton", label: "Export", frame: Rect(x: 600, y: 40, width: 60, height: 24)),
        ]
        #expect(StepMatcher.find("Export as PDF...", in: elements)?.role == "AXMenuItem")
        #expect(StepMatcher.find("File menu", in: elements)?.label == "File")
        #expect(StepMatcher.find("Print", in: elements) == nil)
    }

    @Test func progressAndPromptShapes() {
        #expect(TutorialProgress.parse(#"{"next_step": 3, "done": false}"#) == TutorialProgress(nextStep: 3, done: false))
        let plan = TutorialPlan(intro: "", steps: [TutorialStep(target: "File", instruction: "Open the File menu"),
                                                   TutorialStep(target: "Save", instruction: "Click Save")])
        var check = AskRequest(question: "export this", screenshotJPEG: Data(), screenshotWidth: 640, screenshotHeight: 400,
                               context: ScreenContext())
        check.tutorialCheck = (plan, 2)
        #expect(Prompt.system(for: check) == Prompt.progressSystem)
        #expect(Prompt.userText(for: check).contains("2. Click Save (click \"Save\")"))
        var planning = check
        planning.tutorialCheck = nil
        planning.planTutorial = true
        #expect(Prompt.system(for: planning) == Prompt.tutorialSystem)
        #expect(OllamaProvider.schema(for: planning) != nil)
    }
}
