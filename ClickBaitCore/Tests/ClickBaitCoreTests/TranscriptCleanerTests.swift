import Testing
@testable import ClickBaitCore

struct TranscriptCleanerTests {
    @Test(arguments: ["[BLANK_AUDIO]", "(wind blowing)", "[Music]", "*sigh*", "♪ ♪", " [ Silence ] ", "...", "(  )", ""])
    func nonSpeechBecomesEmpty(_ raw: String) {
        #expect(TranscriptCleaner.clean(raw) == "")
    }

    @Test func keepsSpeech() {
        #expect(TranscriptCleaner.clean(" How do I share this document? ") == "How do I share this document?")
    }

    @Test func stripsTagsAroundSpeech() {
        #expect(TranscriptCleaner.clean("[BLANK_AUDIO] Where is the export button? (keyboard clicking)")
            == "Where is the export button?")
    }

    @Test func collapsesWhitespaceLeftByRemovedTags() {
        #expect(TranscriptCleaner.clean("Open  the *cough* settings\n page") == "Open the settings page")
    }

    @Test func unclosedTagDropsTheRest() {
        #expect(TranscriptCleaner.clean("Click save [inaudible") == "Click save")
    }

    @Test func keepsNumbers() {
        #expect(TranscriptCleaner.clean("Set it to 42") == "Set it to 42")
    }
}
