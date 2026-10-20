import Foundation
import Testing
@testable import ClickBaitCore

/// C4: app cards — the right one, only when the app is named (or a walkthrough runs in it),
/// and every card small.
struct AppCardsTests {
    @Test func thereAreManyAndEachIsSmall() {
        #expect(AppCards.all.count >= 15)
        for card in AppCards.all {
            #expect(card.text.count <= AppCards.maxCharacters, "\(card.app): \(card.text.count)")
            #expect(!card.text.isEmpty)
        }
        let names = AppCards.all.map(\.app)
        #expect(Set(names).count == names.count)
    }

    @Test func aNamedAppGetsItsCard() {
        #expect(AppCards.card(for: "how do I make a checklist in Notes", frontmost: "Finder", planning: false)?.app == "Notes")
        #expect(AppCards.card(for: "open Safari and clear my history", frontmost: nil, planning: false)?.app == "Safari")
        #expect(AppCards.card(for: "how do I clear history in chrome", frontmost: nil, planning: false)?.app == "Google Chrome")
        #expect(AppCards.card(for: "how do I sign a pdf in preview", frontmost: nil, planning: false)?.app == "Preview")
        #expect(AppCards.card(for: "turn on dark mode in system settings", frontmost: nil, planning: false)?.app == "System Settings")
    }

    /// The user's rule: a plain word is not the app.
    @Test func plainWordsAreNotTheApp() {
        #expect(AppCards.card(for: "add milk to my notes", frontmost: nil, planning: false) == nil)
        #expect(AppCards.card(for: "what's in my calendar today", frontmost: nil, planning: false) == nil)
        #expect(AppCards.card(for: "why is the sky blue", frontmost: "Notes", planning: false) == nil)
    }

    @Test func aWalkthroughUsesTheAppInFront() {
        #expect(AppCards.card(for: "how do I make a checklist", frontmost: "Notes", planning: true)?.app == "Notes")
        #expect(AppCards.card(for: "how do I make a checklist", frontmost: "Xcode", planning: true) == nil)
        // A named app wins over the one in front.
        #expect(AppCards.card(for: "how do I add a signature in Mail", frontmost: "Notes", planning: true)?.app == "Mail")
    }

    @Test func itGoesIntoThePrompt() {
        var ask = AskRequest(question: "how do I make a checklist in Notes", screenshotJPEG: Data(), screenshotWidth: 640,
                             screenshotHeight: 400, context: ScreenContext(appName: "Finder"))
        #expect(Prompt.userText(for: ask).contains("About Notes (reference: its menus and shortcuts; may be incomplete):\nNew note:"))
        #expect(Prompt.userText(for: ask).hasSuffix("The user said: how do I make a checklist in Notes"))
        ask.question = "why is the sky blue"
        #expect(!Prompt.userText(for: ask).contains("About "))
        var plan = AskRequest(question: "how do I make a checklist", screenshotJPEG: Data(), screenshotWidth: 640,
                              screenshotHeight: 400, context: ScreenContext(appName: "Notes"))
        plan.planTutorial = true
        #expect(Prompt.userText(for: plan).hasSuffix(AppCards.block(AppCards.lookUp("Notes")!)))
    }
}
