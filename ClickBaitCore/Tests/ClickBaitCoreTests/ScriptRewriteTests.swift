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
