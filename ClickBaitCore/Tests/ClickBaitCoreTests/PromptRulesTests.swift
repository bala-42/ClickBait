import Foundation
import Testing
@testable import ClickBaitCore

/// The answer rules borrowed from HeyClicky's instructions (2026-10-20): result first, no
/// invented facts, no claimed actions, one question when it's ambiguous, no filler.
struct PromptRulesTests {
    @Test func theNormalPromptCarriesTheAnswerRules() {
        let system = Prompt.system
        #expect(system.contains("Lead with the answer: the first sentence of \"speech\" is the result itself"))
        #expect(system.contains("Never invent facts"))
        #expect(system.contains("Never say you did something (opened, sent, saved, changed)"))
        #expect(system.contains("ask one short question naming both"))
        #expect(system.contains("No filler"))
    }

    /// They come before the other rules, so a small model meets them early.
    @Test func theyLeadTheOtherRules() throws {
        let system = Prompt.system
        let rules = try #require(system.range(of: "Other rules:"))
        let lead = try #require(system.range(of: "Lead with the answer"))
        let speech = try #require(system.range(of: "\"speech\" is read aloud"))
        #expect(rules.upperBound < lead.lowerBound && lead.lowerBound < speech.lowerBound)
    }

    /// A plain ask still gets the normal prompt with them.
    @Test func aPlainAskUsesThem() {
        let request = AskRequest(question: "where's the share button?", screenshotJPEG: Data(), screenshotWidth: 640,
                                 screenshotHeight: 400, context: ScreenContext())
        #expect(Prompt.system(for: request).contains("Never invent facts"))
    }
}
