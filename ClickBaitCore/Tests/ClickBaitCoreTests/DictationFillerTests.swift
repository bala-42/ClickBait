import Testing
@testable import ClickBaitCore

/// Filler taken out before the tidy-up ("hi, just" is filler: user, 2026-10-25).
struct DictationFillerTests {
    @Test func fillerOpenersAndHesitationsGo() {
        #expect(Dictation.withoutFillers("Yeah, umm, hi, just send it to Priya.") == "Send it to Priya.")
        #expect(Dictation.withoutFillers("Hi, just checking the build is green") == "Checking the build is green")
        #expect(Dictation.withoutFillers("so um I think it works") == "I think it works")
        #expect(Dictation.withoutFillers("The tests, erm, pass now") == "The tests pass now")
    }

    @Test func realWordsStay() {
        #expect(Dictation.withoutFillers("Yeah, sounds good") == "Yeah, sounds good")
        #expect(Dictation.withoutFillers("So I think we should ship") == "So I think we should ship")
        #expect(Dictation.withoutFillers("I just finished it, I like it") == "I just finished it, I like it")
        #expect(Dictation.withoutFillers("Hi Priya, see you at 3") == "Hi Priya, see you at 3")
        #expect(Dictation.withoutFillers("yeah okay") == "yeah okay")  // nothing else said: kept
        #expect(Dictation.withoutFillers("umm") == "umm")
    }

    @Test func theUsersOwnWords() {
        #expect(Dictation.withoutFillers("It is kind of broken, you see", extra: ["kind of", "you see"]) == "It is broken,")
    }

    @Test func theTidyIsKeptWhenOnlyFillerWasDropped() {
        let heard = Dictation.withoutFillers("Yeah, umm, so, hi, just, okay, send it")
        #expect(Dictation.parseTidy(#"{"text": "Send it."}"#, raw: heard) == "Send it.")
    }
}
