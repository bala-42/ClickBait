import Testing
@testable import ClickBaitCore

struct BrowserTabTests {
    private let sep = BrowserTab.separator

    @Test func onlyChromeAndSafari() {
        #expect(BrowserTab.browser(for: "com.google.Chrome") == .chrome)
        #expect(BrowserTab.browser(for: "com.apple.Safari") == .safari)
        #expect(BrowserTab.browser(for: "com.apple.finder") == nil)
        #expect(BrowserTab.browser(for: nil) == nil)
    }

    @Test func parsesTheCaptureLines() {
        let output = "1234\(sep)567\(sep)Netflix – Audio playing\(sep)https://www.netflix.com/browse\n99\(sep)8\(sep)Inbox\(sep)https://mail.example.com/\n"
        let tabs = BrowserTab.parse(output, browser: .chrome)
        #expect(tabs.count == 2)
        #expect(tabs[0] == BrowserTab(browser: .chrome, windowID: 1234, tab: 567, title: "Netflix – Audio playing",
                                       url: "https://www.netflix.com/browse"))
        #expect(BrowserTab.parse("junk\n\(sep)\(sep)", browser: .chrome).isEmpty)
    }

    @Test func picksTheWindowAccessibilitySawNotJustTheFrontOne() {
        // Two windows at the same spot (one on another desktop): the title decides.
        let tabs = [BrowserTab(browser: .chrome, windowID: 1, tab: 10, title: "Inbox", url: "a"),
                    BrowserTab(browser: .chrome, windowID: 2, tab: 20, title: "Netflix", url: "b")]
        #expect(BrowserTab.pick(tabs, title: "Netflix – Audio playing - Google Chrome – balaji")?.tab == 20)
        #expect(BrowserTab.pick(tabs, title: "Something else")?.tab == 10)
        #expect(BrowserTab.pick([], title: "x") == nil)
    }

    @Test func safariCaptureLooksUnderThePointOrAtEveryWindow() {
        let under = BrowserTab.safariCaptureScript(at: Point(x: -700, y: 600))
        #expect(under.contains("-700 ≥ item 1 of b"))
        #expect(under.contains("current tab of w"))
        #expect(BrowserTab.safariCaptureScript(at: nil).contains("if true then"))
    }

    @Test func safariChecksTheURLAndEscapesIt() {
        let script = BrowserTab(browser: .safari, windowID: 7, tab: 3, title: "t", url: "https://x.com/?q=\"hi\"").safariReturnScript
        #expect(script.contains("window id 7"))
        #expect(script.contains("(URL of tab 3 of w) is \"https://x.com/?q=\\\"hi\\\"\""))
    }
}
