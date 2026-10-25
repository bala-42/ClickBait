import Foundation
import Testing
@testable import ClickBaitCore

/// A follow-up on an unchanged screen reuses the first screenshot (2026-10-25).
struct FollowUpScreenTests {
    let thumb = [UInt8](repeating: 120, count: ScreenChange.width * ScreenChange.height)

    @Test func onlyAnUnchangedScreenMatches() {
        #expect(ScreenChange.same(thumb, thumb))
        var noise = thumb; noise[50] = 124
        #expect(ScreenChange.same(thumb, noise))
        var changed = thumb; changed[500] = 200  // one new mark on screen
        #expect(!ScreenChange.same(thumb, changed))
        #expect(!ScreenChange.same(thumb, Array(thumb.prefix(10))))
    }

    @Test func theFirstScreenshotGoesBackInItsPlace() throws {
        var conversation = Conversation()
        conversation.append(user: "What app is in front?", assistantSpeech: "Finder.")
        conversation.remember(.init(jpeg: Data([1, 2]), width: 1280, height: 720, thumbnail: thumb))
        let plain = conversation.history.allSatisfy { $0.images.isEmpty }
        #expect(plain)  // as before, unless reused
        #expect(conversation.historyReusingScreen.first?.images == [Data([1, 2])])
        conversation.append(user: "And else?", assistantSpeech: "Safari.")
        conversation.remember(.init(jpeg: Data([9]), width: 1, height: 1, thumbnail: thumb))  // only the first
        #expect(conversation.screen?.jpeg == Data([1, 2]))

        var request = AskRequest(question: "what else is open?", screenshotJPEG: Data(), screenshotWidth: 1280, screenshotHeight: 720,
                                 context: ScreenContext(), history: conversation.historyReusingScreen)
        request.sameScreen = true
        #expect(Prompt.userText(for: request).contains("The screen hasn't changed"))
        let body = OllamaProvider.chatBody(for: request, model: "gemma4:e4b")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect((messages[1]["images"] as? [String])?.count == 1)  // the first question carries it
        let lastImages = messages.last?["images"]
        #expect(lastImages == nil)  // the follow-up sends none
    }
}
