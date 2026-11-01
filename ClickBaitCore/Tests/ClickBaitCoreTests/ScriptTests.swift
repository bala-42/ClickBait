import Testing
@testable import ClickBaitCore

struct ScriptTests {
    @Test func headingsBecomeCues() {
        let script = Script(text: "# Intro\nHi, I'm Bala.\n\n## The demo\nHere's the notch.\n\nOUTRO\nThanks!")
        #expect(script.cues.map(\.title) == ["Intro", "The demo", "Outro"])
        #expect(script.cues[1].start == "# Intro\nHi, I'm Bala.\n\n".count)
    }

    @Test func colonsAndDividers() {
        let script = Script(text: "Opening:\nWelcome everyone.\n---\nSo today we look at pricing and what changed.")
        #expect(script.cues.map(\.title) == ["Opening", "So today we look at pricing…"])
    }

    @Test func plainParagraphsWhenThereAreNoMarks() {
        let script = Script(text: "First we open the app and say hello.\n\nThen we show the shelf.")
        #expect(script.cues.map(\.title) == ["First we open the app and…", "Then we show the shelf."])
        #expect(script.cue(at: 50)?.title == "Then we show the shelf.")
    }

    @Test func sentencesAreNotHeadings() {
        #expect(Script.heading("Note: this ends with a colon but is long enough to be a sentence, really:") == nil)
        #expect(Script.heading("OK.") == nil)
        #expect(Script.heading("Q&A") == nil)  // under three letters
    }

    @Test func readableDropsMarks() {
        #expect(Script(text: "# Intro\nHi\n---\nBye").readable == "Intro\nHi\n\nBye")
    }
}
