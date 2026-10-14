import Testing
@testable import ClickBaitCore

struct HomeWindowTests {
    private let asked = Rect(x: 100, y: 80, width: 900, height: 600)

    @Test func titleAndFrameBeatTitleAlone() {
        let windows: [(title: String?, frame: Rect?)] = [
            ("Notes", Rect(x: 0, y: 0, width: 500, height: 400)),
            ("Notes", asked),
        ]
        #expect(HomeWindow.best(windows, title: "Notes", frame: asked) == 1)
    }

    @Test func aMovedWindowStillMatchesByTitle() {
        let windows: [(title: String?, frame: Rect?)] = [("Inbox", asked), ("Report.pdf", Rect(x: 400, y: 300, width: 900, height: 600))]
        #expect(HomeWindow.best(windows, title: "Report.pdf", frame: asked) == 1)
    }

    @Test func aRetitledWindowMatchesByFrame() {
        let windows: [(title: String?, frame: Rect?)] = [("Other", Rect(x: 0, y: 0, width: 300, height: 300)),
                                                         ("New Tab", Rect(x: 101, y: 79, width: 900, height: 601))]
        #expect(HomeWindow.best(windows, title: "Old Tab", frame: asked) == 1)
    }

    @Test func theBrowserSuffixDoesntMatter() {
        #expect(HomeWindow.titlesMatch("Solar System - Wikipedia - Google Chrome", "Solar System - Wikipedia"))
        #expect(HomeWindow.titlesMatch("Apple — Safari", "apple"))
        #expect(!HomeWindow.titlesMatch("Solar System", "Solar System 2"))
        #expect(HomeWindow.pageTitle("Notes - Draft") == "notes - draft")  // not an app: kept
        // Chrome's real window title: the profile follows the browser, with mixed dashes.
        #expect(HomeWindow.pageTitle("Netflix – Audio playing - Google Chrome – balaji") == "netflix – audio playing")
        #expect(HomeWindow.pageTitle("(189) Unisport - YouTube - Google Chrome – balaji") == "(189) unisport - youtube")
    }

    @Test func tabsMatchThroughChromesStatusWords() {
        let saved = "Netflix – Audio playing - Google Chrome – balaji"
        #expect(HomeWindow.tabMatches("Netflix – Audio playing", page: saved))
        #expect(HomeWindow.tabMatches("Netflix", page: saved))  // the sound stopped since
        #expect(HomeWindow.tabMatches("Netflix – Audio playing", page: "Netflix - Google Chrome – balaji"))
        #expect(!HomeWindow.tabMatches("lube for latex", page: saved))
        #expect(!HomeWindow.tabMatches("Net", page: saved))  // too short to be sure
    }

    @Test func stackedChromeWindowsAreToldApartByTitle() {
        // Same frame, but the title picks the right one of stacked browser windows.
        let stacked: [(title: String?, frame: Rect?)] = [("Inbox - Google Chrome", asked), ("Solar System - Google Chrome", asked)]
        #expect(HomeWindow.best(stacked, title: "Solar System", frame: asked) == 1)
    }

    @Test func nothingMatchingIsNil() {
        let windows: [(title: String?, frame: Rect?)] = [("A", Rect(x: 0, y: 0, width: 10, height: 10))]
        #expect(HomeWindow.best(windows, title: "B", frame: asked) == nil)
        #expect(HomeWindow.best(windows, title: nil, frame: nil) == nil)
        #expect(HomeWindow.best([("", nil)], title: "", frame: nil) == nil)
    }
}
