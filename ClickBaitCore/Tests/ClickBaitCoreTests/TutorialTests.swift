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

struct TutorialPaddingTests {
    @Test func repeatedStepsAreDropped() {
        let raw = #"{"speech": "s", "steps": [{"target": "History", "instruction": "Open History"}, {"target": "Clear History…", "instruction": "Choose Clear History…"}, {"target": "Clear History", "instruction": "Click Clear History"}, {"target": "History", "instruction": "Open History again"}]}"#
        // "Clear History…" (the menu item) and "Clear History" (the dialog's button) are two
        // real steps in Safari; only the repeated "History" is padding.
        #expect(TutorialPlan.parse(raw)?.steps.map(\.target) == ["History", "Clear History…", "Clear History"])
    }
}

struct TutorialMenuTests {
    private let safari = ["History ▸ Show All History", "History ▸ Clear History…", "History ▸ Back",
                          "File ▸ Export as PDF…", "View ▸ Show Sidebar"]

    @Test func aMenuStepGetsTheItemItNames() {
        // Real qwen2.5vl:7b plans with Safari's menus offered.
        let one = TutorialPlan.parse(#"{"speech": "Open the History menu and choose Clear History.", "steps": [{"instruction": "Open the History menu", "target": "History"}]}"#)!
        #expect(one.expandingMenus(using: safari).steps.map(\.target) == ["History", "Clear History…"])
        let inline = TutorialPlan.parse(#"{"steps": [{"instruction": "History ▸ Clear History…", "target": "History"}], "speech": "Open the History menu and choose Clear History…."}"#)!
        #expect(inline.expandingMenus(using: safari).steps.map(\.target) == ["History", "Clear History…"])
    }

    @Test func leavesCompletePlansAlone() {
        let full = TutorialPlan(intro: "", steps: [TutorialStep(target: "History", instruction: "Open History"),
                                                   TutorialStep(target: "Clear History…", instruction: "Choose Clear History…")])
        #expect(full.expandingMenus(using: safari).steps.count == 2)
        let unrelated = TutorialPlan(intro: "Zoom in.", steps: [TutorialStep(target: "View", instruction: "Open View")])
        #expect(unrelated.expandingMenus(using: safari).steps.count == 1)
    }
}

struct TutorialContinuationTests {
    private let done = [TutorialStep(target: "History", instruction: "Open History"),
                        TutorialStep(target: "Clear History…", instruction: "Choose Clear History…"),
                        TutorialStep(target: "Clear History", instruction: "Click Clear History")]

    @Test func aPlanThatStartsOverMeansFinished() {
        // After the history was cleared, the model planned the whole task again.
        let again = TutorialPlan(intro: "", steps: [TutorialStep(target: "History", instruction: "Open History"),
                                                    TutorialStep(target: "Clear History…", instruction: "Choose Clear History…")])
        #expect(TutorialPlan.remaining(again, after: done) == nil)
    }

    @Test func genuinelyNewStepsContinue() {
        let next = TutorialPlan(intro: "", steps: [TutorialStep(target: "the last hour", instruction: "Choose the last hour"),
                                                   TutorialStep(target: "Clear History", instruction: "Click Clear History")])
        #expect(TutorialPlan.remaining(next, after: Array(done.prefix(2)))?.map(\.target) == ["the last hour", "Clear History"])
    }
}

struct MenuOutlineTests {
    @Test func keepsTitlesAndTheItemsTheQuestionNames() {
        let safari = ["Safari ▸ About Safari", "Safari ▸ Clear History…", "File ▸ New Window", "File ▸ Export as PDF…",
                      "History ▸ Back", "History ▸ Show All History", "History ▸ Clear History…", "Window ▸ Minimise"]
        let kept = MenuOutline.relevant(safari, to: "how do I clear the last hour of my Safari history")
        #expect(kept.contains("History ▸ Clear History…") && kept.contains("Safari ▸ Clear History…"))
        #expect(kept.contains("History ▸ Show All History"))  // "history" matches
        #expect(kept.contains("File") && kept.contains("Window"))  // titles of other menus only
        #expect(!kept.contains("File ▸ New Window"))
    }

    @Test func textOnlyPromptSaysSo() {
        var request = AskRequest(question: "q", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0, context: ScreenContext())
        request.planTutorial = true
        #expect(Prompt.userText(for: request).hasPrefix("No screenshot"))
        #expect(TutorialPlanning.canUseTextOnly(elements: 2, menuItems: 40))
        #expect(!TutorialPlanning.canUseTextOnly(elements: 1, menuItems: 2))
    }
}

struct TutorialAppTests {
    @Test func aTaskInAnotherAppNamesIt() {
        let plan = TutorialPlan.parse(#"{"speech": "That's in Safari.", "app": "Safari", "steps": []}"#)
        #expect(plan?.app == "Safari")
        #expect(TutorialPlan.parse(#"{"speech": "s", "app": "", "steps": []}"#)?.app == nil)
    }
}

struct TutorialSetupTests {
    private let apps: Set<String> = ["safari", "notes", "system settings", "finder"]
    private func installed(_ name: String) -> Bool { apps.contains(name.lowercased()) }

    @Test func openingAnotherAppBecomesSetup() {
        // Real qwen2.5vl:7b plan with Notes in front.
        let plan = TutorialPlan.parse(#"{"speech": "Open Safari and go to the History menu.", "steps": [{"target": "Safari", "instruction": "Open Safari."}, {"target": "History", "instruction": "Go to the History menu."}, {"target": "Clear History…", "instruction": "Choose Clear History…"}]}"#)!
        let split = plan.separatingSetup(frontmostApp: "Notes", isInstalledApp: installed)
        #expect(split.app == "Safari")
        #expect(split.steps.map(\.target) == ["History", "Clear History…"])
    }

    @Test func openingTheAppInFrontIsDropped() {
        let plan = TutorialPlan.parse(#"{"speech": "s", "steps": [{"instruction": "Open the Notes app.", "target": "Notes"}]}"#)!
        let split = plan.separatingSetup(frontmostApp: "Notes", isInstalledApp: installed)
        #expect(split.app == nil && split.steps.isEmpty)
    }

    @Test func ordinaryStepsAreUntouched() {
        let plan = TutorialPlan(intro: "", steps: [TutorialStep(target: "History", instruction: "Open History")])
        let split = plan.separatingSetup(frontmostApp: "Safari", isInstalledApp: installed)
        #expect(split.app == nil)
        #expect(split.steps == [TutorialStep(target: "History", instruction: "Open History", app: "Safari")])
    }

    @Test func stepsAcrossAppsKnowTheirApp() {
        // "Open Notes" mid-plan: ClickBait switches; the steps after it are in Notes.
        let plan = TutorialPlan.parse(#"{"speech": "s", "steps": [{"target": "Share", "instruction": "Click Share"}, {"target": "Copy Link", "instruction": "Choose Copy Link"}, {"target": "Notes", "instruction": "Open Notes"}, {"target": "New Note", "instruction": "Click New Note"}, {"target": "⌘V", "instruction": "Press ⌘V to paste"}]}"#)!
        let split = plan.separatingSetup(frontmostApp: "Safari", isInstalledApp: installed)
        #expect(split.app == nil)
        #expect(split.steps.map(\.target) == ["Share", "Copy Link", "New Note", "⌘V"])
        #expect(split.steps.map(\.app) == ["Safari", "Safari", "Notes", "Notes"])
        #expect(split.apps == ["Safari", "Notes"])
        #expect(split.checklist(done: 1).hasPrefix("In Safari:\n✓ Click Share\n2. Choose Copy Link\nIn Notes:\n3. Click New Note"))
    }

    @Test func clickBaitAndOldNamesAreNotApps() {
        // Real qwen2.5vl:7b plans: "Open Notes" tagged ClickBait; System Preferences.
        let plan = TutorialPlan.parse(#"{"speech": "s", "steps": [{"instruction": "Copy the page's link", "target": "Copy", "app": "Safari"}, {"instruction": "Open Notes", "target": "Notes", "app": "ClickBait"}, {"instruction": "Paste it", "target": "Paste", "app": "ClickBait"}, {"target": "Wallpaper", "instruction": "Choose Wallpaper", "app": "System Preferences"}]}"#)!
        let split = plan.separatingSetup(frontmostApp: "Safari", isInstalledApp: installed)
        #expect(split.steps.map(\.app) == ["Safari", "Notes", "System Settings"])
    }

    @Test func modelGivenAppsAreKept() {
        let plan = TutorialPlan.parse(#"{"speech": "s", "steps": [{"target": "History", "instruction": "Open History", "app": "Safari"}, {"target": "Clear History…", "instruction": "Choose it", "app": "Safari"}]}"#)!
        let split = plan.separatingSetup(frontmostApp: "Notes", isInstalledApp: installed)
        #expect(split.app == "Safari")  // opened before the lesson starts
        #expect(split.steps.count == 2)
        #expect(split.checklist(done: 0) == "1. Open History\n2. Choose it")  // one app: no headers
    }
}

struct NoteReferenceTests {
    @Test(arguments: [("Add this pages URL into the notes", NoteReference.pageAddress), ("Note this link", .pageAddress),
                      ("Save this page to my notes", .pageAddress), ("Make a note of the selected text", .selection),
                      ("Jot down that the plumber comes Tuesday", nil), ("Remind me to call mum", nil)])
    func references(_ order: String, _ expected: NoteReference?) {
        #expect(NoteReference.find(in: order) == expected)
    }

    @Test func pageNotes() {
        #expect(NoteReference.noteText(address: "https://apple.com", title: "Apple") == "Apple\nhttps://apple.com")
        #expect(NoteReference.noteText(address: "https://apple.com", title: nil) == "https://apple.com")
    }
}

struct TutorialOrderTests {
    @Test(arguments: [("Write me a poem about cats", true), ("Summarise this note", true), ("Please explain this error", true),
                      ("Clear search history.", false), ("Turn on two-factor authentication", false)])
    func contentRequests(_ text: String, _ expected: Bool) {
        #expect(TutorialQuestion.isContentRequest(text) == expected)
    }

    @Test func namedApps() {
        let apps = ["Safari", "Notes", "System Settings", "Mail", "Music"]
        #expect(TutorialQuestion.mentionedApp(in: "Clear my Safari history.", apps: apps) == "Safari")
        #expect(TutorialQuestion.mentionedApp(in: "turn off notifications in system settings", apps: apps) == "System Settings")
        #expect(TutorialQuestion.mentionedApp(in: "send an email", apps: apps) == nil)  // "email" isn't the word "Mail"
        #expect(TutorialQuestion.mentionedApp(in: "clear search history", apps: apps) == nil)
    }
}

struct TutorialLabelTests {
    @Test(arguments: [
        (#"Click button "Share" at (980, 52)"#, "Click Share"),
        ("Click the Clear History button at (640, 400).", "Click the Clear History button."),
        (#"Choose menu item "Clear History…" (id: 7)"#, "Choose Clear History…"),
        ("Click element 12 to open the File menu", "Click to open the File menu"),
        ("Open the History menu (x: 541, y: 16)", "Open the History menu"),
        ("Open the History menu", "Open the History menu"),
    ])
    func instructionsLoseCoordinates(_ raw: String, _ expected: String) {
        #expect(TutorialPlan.cleanInstruction(raw) == expected)
    }

    @Test func parsedPlansAreClean() {
        let raw = #"{"speech": "Here's how (see 980, 52).", "steps": [{"target": "Share", "instruction": "Click button \"Share\" at (980, 52)"}, {"target": "Copy Link", "instruction": "Choose Copy Link"}]}"#
        let plan = TutorialPlan.parse(raw)
        #expect(plan?.steps.first?.instruction == "Click Share")
    }
}

struct FindVersusDoTests {
    @Test(arguments: [
        // Finding a thing → blue pointing.
        ("Where is the refresh button?", true, false), ("Show me the refresh button.", true, false),
        ("Point at the share button", true, false), ("Find the bookmarks bar", true, false),
        // Doing a task → lavender tutorial.
        ("Refresh the page.", false, false), ("How do I refresh?", false, true), ("Show me how to refresh this", false, true),
    ])
    func findingVersusDoing(_ text: String, _ locating: Bool, _ tutorial: Bool) {
        #expect(TutorialQuestion.isLocatingRequest(text) == locating)
        #expect(TutorialQuestion.asksForTutorial(text) == tutorial)
    }

    @Test func refreshThePageIsAnOrder() {
        #expect(CommandParser.looksLikeOrder("Refresh the page.") && !TutorialQuestion.isContentRequest("Refresh the page."))
    }
}
