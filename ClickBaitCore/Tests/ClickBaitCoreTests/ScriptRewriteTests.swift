import Testing
@testable import ClickBaitCore

struct ScriptRewriteTests {
    @Test func cleansTheBrainsReply() {
        let reply = "Here's your script:\n```\n**Opening**\nHi there.\n# Demo\nLook at this.\n```"
        #expect(ScriptRewrite.cleaned(reply) == "# Opening\nHi there.\n# Demo\nLook at this.")
    }

    @Test func cuesOnlyMustKeepEveryWord() {
        let original = "Hi there.\nLook at this."
        #expect(ScriptRewrite.keepsWords(original: original, rewritten: "# Opening\nHi there.\n# Demo\nLook at this."))
        #expect(!ScriptRewrite.keepsWords(original: original, rewritten: "# Opening\nHello there.\n# Demo\nLook at this."))
    }

    @Test func aSpeakableRewriteMustBeASimilarLengthWithCues() {
        let original = String(repeating: "We are going to look at the quarterly numbers today. ", count: 4)
        #expect(ScriptRewrite.plausible(original: original, rewritten: "# Numbers\n" + String(repeating: "Let's look at this quarter's numbers today. ", count: 4)))
        #expect(!ScriptRewrite.plausible(original: original, rewritten: "# Summary\nNumbers."))          // summarised
        #expect(!ScriptRewrite.plausible(original: original, rewritten: original))                       // no cues
    }
}

struct ScriptOrganizerTests {
    @Test func splitsSentencesLeavingOldHeadingsOut() {
        let sentences = ScriptOrganizer.sentences(of: "# Old\nHi there. I'm Bala!\n---\nWhat's new? Studio.")
        #expect(sentences == ["Hi there.", "I'm Bala!", "What's new?", "Studio."])
    }

    @Test func rebuildsFromTheExactSentencesNothingLost() {
        let sentences = ["Hi all.", "Studio has a mirror.", "Search finds pictures.", "The prompter follows you.", "Bye!"]
        let text = ScriptOrganizer.assemble(sentences, sections: [
            .init(title: "Hello", sentences: [1]),
            .init(title: "# Studio", sentences: [2, 4, 2]),       // a repeat, a stray mark
            .init(title: "Search", sentences: [3, 9]),            // out of range
            // 5 forgotten: it joins the section of 4
        ])
        #expect(text == "# Hello\nHi all.\n\n# Studio\nStudio has a mirror. The prompter follows you. Bye!\n\n# Search\nSearch finds pictures.")
        #expect(ScriptOrganizer.assemble(sentences, sections: []) == nil)
    }
}
