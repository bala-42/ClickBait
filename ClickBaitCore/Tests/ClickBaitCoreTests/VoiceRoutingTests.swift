import Testing
@testable import ClickBaitCore

/// Voice → intent → target (2026-10-14): app names are words unless the request sends
/// ClickBait there; voice alone never points; typing goes to the caret in the app in front.
struct VoiceRoutingTests {
    private let apps = ["Claude", "Messages", "Notes", "Terminal", "Safari", "Google Chrome", "System Settings", "Preview"]

    // MARK: Words that are app names

    @Test func aMentionIsJustWords() {
        #expect(TutorialQuestion.locatingApp(in: "where do I type my message to Claude", apps: apps) == nil)
        #expect(TutorialQuestion.locatingApp(in: "where do I put my notes about Terminal", apps: apps) == nil)
        #expect(TutorialQuestion.locatingApp(in: "show me the messages from Claude", apps: apps) == nil)
        // The old rule would have switched app on each of these.
        #expect(TutorialQuestion.mentionedApp(in: "where do I type my message to Claude", apps: apps) == "Claude")
    }

    @Test func anExplicitRequestStillGoesThere() {
        #expect(TutorialQuestion.locatingApp(in: "show me the share button in Safari", apps: apps) == "Safari")
        #expect(TutorialQuestion.locatingApp(in: "open Messages and show me where to type", apps: apps) == "Messages")
        #expect(TutorialQuestion.locatingApp(in: "where's the bookmarks bar in Google Chrome", apps: apps) == "Google Chrome")
        #expect(TutorialQuestion.locatingApp(in: "switch to Notes and find the new note button", apps: apps) == "Notes")
    }

    @Test func macSettingsStillOpenSystemSettings() {
        #expect(TutorialQuestion.locatingApp(in: "where's the bluetooth setting", apps: apps) == "System Settings")
    }

    // MARK: Plain text composition

    @Test func composingAMessageNeitherPointsNorSwitches() {
        let request = "write a message to Claude saying the build passed"
        #expect(!InstantAnswer.allowsPointing(request))
        #expect(!InstantAnswer.asksWhereToType(request))
        #expect(TutorialQuestion.locatingApp(in: request, apps: apps) == nil)
    }

    // MARK: Caret targeting

    @Test func shortTypingQuestionsGoToTheCaret() {
        for question in ["where do I type my message?", "where can I write my reply", "where's the input field",
                         "where do I type in this editor", "show me the text box"] {
            #expect(InstantAnswer.asksWhereToType(question), "\(question)")
        }
    }

    // MARK: Voice-triggered pointing

    /// The run of 2026-10-14 18:13 and 18:14: a long spoken ramble, the model's reply naming
    /// a menu-bar control → pointed at it. Now: no pointer of any kind.
    @Test func aRambleNeverPoints() {
        let ramble = "so where I was going with this is that when I talk to it and then it goes and does something I didn't ask for and points somewhere up in the menu bar"
        #expect(ImpliedPointer.isLocating(ramble))  // why it got through before
        #expect(!InstantAnswer.allowsPointing(ramble))
        #expect(!InstantAnswer.allowsUnnamedPick(ramble))
    }

    @Test func explicitWhereQuestionsStillPoint() {
        #expect(InstantAnswer.allowsPointing("where's the share button"))
        #expect(InstantAnswer.allowsPointing("show me the refresh button"))
        #expect(InstantAnswer.allowsPointing("which button saves this?"))
    }

    @Test func aControlOnlyTheAnswerNamesIsNotPointedAt() {
        // The reply mentioned "Messages" (the app menu); the question didn't ask about it.
        #expect(!InstantAnswer.unnamedPick("Messages", fits: "where do I type my reply"))
        #expect(InstantAnswer.unnamedPick("Reply", fits: "where do I type my reply"))
    }
}
