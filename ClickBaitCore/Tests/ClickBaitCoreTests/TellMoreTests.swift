import Foundation
import Testing
@testable import ClickBaitCore

struct TellMoreTests {
    @Test func tellMoreAsksForTheFullExplanation() {
        var request = AskRequest(question: "tell me more", screenshotJPEG: Data([1]), screenshotWidth: 100, screenshotHeight: 100,
                                 context: ScreenContext(appName: "Safari"))
        #expect(!Prompt.userText(for: request).contains("explain it in depth"))
        request.detailed = true
        #expect(Prompt.userText(for: request).contains("explain it in depth"))
        #expect(PeelRule.tellMorePrompt == "tell me more")
    }
}
