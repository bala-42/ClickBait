import Testing
@testable import ClickBaitCore

/// "who is Steve Jobs?" then "elaborate": the follow-up stays about Steve Jobs (2026-10-25).
struct FollowUpOffScreenTests {
    @Test func vagueFollowUpsStayOffTheScreen() {
        for question in ["elaborate", "tell me more", "why?", "elaborate on that", "and his early life?", "what about this one?"] {
            #expect(!ScreenNeed.followUpNeedsScreen(question), "\(question)")
        }
    }

    @Test func followUpsNamingTheScreenGetIt() {
        for question in ["what's in this window?", "where do I click?", "what's on my screen?", "what about the highlighted part",
                         "where is the share button"] {
            #expect(ScreenNeed.followUpNeedsScreen(question), "\(question)")
        }
    }

    @Test func askingForMoreIsAboutTheLastAnswer() {
        for question in ["tell me more", "elaborate", "go on", "can you explain more?", "tell me more about it", "more details please"] {
            #expect(ScreenNeed.asksForMore(question), "\(question)")
        }
        for question in ["what is a palindrome", "where is the more button", "who is Steve Jobs"] {
            #expect(!ScreenNeed.asksForMore(question) || ScreenNeed.followUpNeedsScreen(question), "\(question)")
        }
    }
}
