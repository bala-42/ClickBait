import Testing
@testable import ClickBaitCore

/// "Who is Steve Jobs" was sent with a screenshot of Notes and answered "can't tell you right
/// now" (2026-10-24): world questions go without the screen, and with 🌐 on they check Wikipedia.
struct WorldQuestionTests {
    @Test(arguments: ["who is steve jobs", "hey, can you tell me who Steve Jobs is?", "ClickBait, who was Ada Lovelace",
                      "tell me about the Eiffel Tower", "what is the capital of Peru"])
    func worldQuestionsGoWithoutTheScreen(_ question: String) {
        #expect(ScreenNeed.isAboutTheWorld(question))
        #expect(WebLookup.reason(for: question) == .world)
    }

    @Test(arguments: ["who made this", "what is this button", "tell me what's on my screen", "who is in this photo"])
    func screenQuestionsKeepTheScreen(_ question: String) {
        #expect(!ScreenNeed.isAboutTheWorld(question))
        #expect(WebLookup.reason(for: question) != .world)
    }

    @Test func followUpsStandAloneOnlyWithTheirOwnSubject() {
        #expect(ScreenNeed.isAboutTheWorld("who is Steve Wozniak", followUp: true))
        #expect(!ScreenNeed.isAboutTheWorld("who is he married to", followUp: true))
    }

    @Test func clickBaitsOwnNameIsntPointing() {
        #expect(!ImpliedPointer.isLocating("ClickBait, who was Ada Lovelace"))
        #expect(ImpliedPointer.isLocating("ClickBait, where's the share button"))
    }

    @Test func notEveryWorldQuestionGoesOnline() {
        #expect(ScreenNeed.isAboutTheWorld("why is the sky blue"))
        #expect(WebLookup.reason(for: "why is the sky blue") == nil)
    }
}
