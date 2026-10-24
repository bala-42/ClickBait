import Testing
@testable import ClickBaitCore

struct MacGuideTests {
    @Test func knownTasksPlanAtOnce() throws {
        let hidden = try #require(MacGuide.plan(for: "how do I show hidden files"))
        #expect(hidden.steps.map(\.target) == ["⌘⇧."])
        #expect(hidden.steps.first?.app == "Finder")
        #expect(hidden.steps.first?.isShortcut == true)

        let history = try #require(MacGuide.plan(for: "show me how to clear my safari history"))
        #expect(history.steps.map(\.target) == ["History", "Clear History…"])
        #expect(history.steps.allSatisfy { $0.app == "Safari" })
    }

    @Test func menuBarTasksWorkFromAnyApp() throws {
        let center = try #require(MacGuide.plan(for: "where is control center"))
        #expect(center.steps.first?.app == nil)
        let quit = try #require(MacGuide.plan(for: "how do I force quit an app"))
        #expect(quit.steps.map(\.target) == ["Apple", "Force Quit…"])
    }

    @Test func longestPhraseWins() throws {
        // "clear chrome history" beats Safari's shorter "safari history"-free match.
        let chrome = try #require(MacGuide.plan(for: "how do I clear chrome history"))
        #expect(chrome.steps.first?.app == "Google Chrome")
    }

    @Test func aTaskBothBrowsersHaveFollowsTheAppInFront() throws {
        #expect(try #require(MacGuide.plan(for: "reopen closed tab", app: "Google Chrome")).steps.first?.app == "Google Chrome")
        #expect(try #require(MacGuide.plan(for: "reopen closed tab", app: "Safari")).steps.first?.app == "Safari")
        #expect(try #require(MacGuide.plan(for: "open a private window", app: "Google Chrome")).steps.last?.target == "New Incognito window")
    }

    @Test func picksThisMacsSpelling() throws {
        let british = try #require(MacGuide.plan(for: "empty the bin", outline: ["Finder ▸ Empty Bin…"]))
        #expect(british.steps.last?.target == "Empty Bin…")
        #expect(british.steps.last?.instruction == "Choose Empty Bin…")
        #expect(try #require(MacGuide.plan(for: "empty trash")).steps.last?.target == "Empty Trash…")
    }

    @Test func unknownTasksAreLeftToThePlanner() {
        #expect(MacGuide.plan(for: "how do I make this paragraph bold") == nil)
        #expect(MacGuide.plan(for: "what does this error mean") == nil)
    }

    @Test func factsFavourTheAppAndAddPlaceNotes() {
        let facts = MacGuide.facts(for: "how do I see my downloads", app: "Google Chrome")
        #expect(facts.first?.hasPrefix("Google Chrome:") == true)
        #expect(facts.contains { $0.hasPrefix("Chrome: the address bar") })
        #expect(MacGuide.facts(for: "how do I find history on youtube", app: "Safari").contains { $0.hasPrefix("YouTube:") })
        #expect(MacGuide.facts(for: "hi", app: nil).isEmpty)
    }

    @Test func rememberedMenusGiveAPath() {
        let lines = ["History ▸ Show All History", "History ▸ Clear History…", "View ▸ Show Reader"]
        #expect(MenuOutline.path(to: "Clear History", in: lines) == ["History", "Clear History…"])
        #expect(MenuOutline.path(to: "clear history…", in: lines) == ["History", "Clear History…"])
        #expect(MenuOutline.path(to: "History", in: lines) == nil)  // a menu, not an item
        #expect(MenuOutline.path(to: "Print", in: lines) == nil)
    }

    @Test func everyEntryIsUsable() {
        for entry in MacGuide.entries {
            #expect(!entry.phrases.isEmpty && !entry.steps.isEmpty)
            for phrase in entry.phrases { #expect(phrase == ImpliedPointer.normalized(phrase), "\(phrase)") }
        }
    }
}
