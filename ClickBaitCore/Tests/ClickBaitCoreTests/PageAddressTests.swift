import Foundation
import Testing
@testable import ClickBaitCore

struct PageAddressTests {
    @Test func keepsTheSiteAndPathOnly() {
        #expect(ScreenContext.cleanAddress("https://www.example.com/a/b?token=secret#top") == "example.com/a/b")
        #expect(ScreenContext.cleanAddress("http://en.wikipedia.org/wiki/The_Garden_of_Earthly_Delights") == "en.wikipedia.org/wiki/The_Garden_of_Earthly_Delights")
        #expect(ScreenContext.cleanAddress("https://apple.com/") == "apple.com")
        #expect(ScreenContext.cleanAddress("file:///Users/me/notes.html") == nil)
        #expect(ScreenContext.cleanAddress("chrome://settings") == nil)
        #expect(ScreenContext.cleanAddress("not a url") == nil)
    }

    @Test func theAnswerKnowsTheWebPage() {
        var context = ScreenContext(appName: "Google Chrome", windowTitle: "The Garden of Earthly Delights - Wikipedia")
        context.pageAddress = "en.wikipedia.org/wiki/The_Garden_of_Earthly_Delights"
        let request = AskRequest(question: "what's this page?", screenshotJPEG: Data([1]), screenshotWidth: 10, screenshotHeight: 10, context: context)
        #expect(Prompt.userText(for: request).contains("Web page: en.wikipedia.org/wiki/The_Garden_of_Earthly_Delights"))
        let without = AskRequest(question: "what's this?", screenshotJPEG: Data([1]), screenshotWidth: 10, screenshotHeight: 10, context: ScreenContext(appName: "Notes"))
        #expect(!Prompt.userText(for: without).contains("Web page:"))
    }
}
