import Testing
@testable import ClickBaitCore

struct PillTextTests {
    @Test(arguments: ["Yep, it's on!", "Saturday the 11th.", "Share's up here!", "About 20 minutes.", "Added to Reminders for today"])
    func shortFriendlyRepliesFit(_ text: String) {
        #expect(PillText.fits(text))
    }

    @Test(arguments: [
        "Click the Share button in the top right corner of the window.",   // too long
        "Yes. It's on.",                                                    // two sentences
        "Sure! Here you go",                                                // two sentences
        "Line one\nline two",
        "",
    ])
    func othersGoToTheChat(_ text: String) {
        #expect(!PillText.fits(text))
    }

    @Test func codeAlwaysGoesToTheChat() {
        #expect(!PillText.fits("Use this:", code: "ls -la"))
    }
}
