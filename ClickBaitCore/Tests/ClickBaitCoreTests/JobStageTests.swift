import Testing
@testable import ClickBaitCore

/// C6: a running tile says what it's doing until its answer starts writing.
struct JobStageTests {
    @Test func theStageShowsUntilTheAnswerStarts() {
        #expect(JobSummary.liveLine(from: "", stage: .readingScreen) == "Reading your screen…")
        #expect(JobSummary.liveLine(from: "", stage: .lookingUp) == "Looking it up on the web…")
        #expect(JobSummary.liveLine(from: "", stage: nil) == "working on it…")
        #expect(JobSummary.liveLine(from: "It's under File.", stage: .thinking) == "It's under File.")
    }

    @Test func everyStageHasItsLine() {
        let stages: [JobStage] = [.readingScreen, .thinking, .lookingUp, .planningSteps]
        #expect(Set(stages.map(\.text)).count == stages.count)
        #expect(stages.allSatisfy { $0.text.hasSuffix("…") })
    }
}

/// The result pill: a headline, never a paragraph (user's rule, 2026-10-20).
struct JobHeadlineTests {
    @Test func aShortFirstSentenceIsTheHeadline() {
        #expect(JobSummary.headline(from: "It's under File. Then pick Export.") == "It's under File.")
    }

    @Test func longOnesAreCutAtANaturalBreak() {
        let answer = "Andrew Friedman, the Dodgers' president of baseball operations, built their recent championship rosters."
        let headline = JobSummary.headline(from: answer)
        #expect(headline == "Andrew Friedman, the Dodgers' president of…")  // a 15-character break says too little
        #expect(JobSummary.headline(from: "The quarterly revenue grew by twelve percent, mostly from services in Asia.")
            == "The quarterly revenue grew by twelve percent…")
        #expect(headline.count <= JobSummary.headlineLength + 1)
    }

    @Test func otherwiseAtAWord() {
        let answer = "Rayleigh scattering makes shorter blue wavelengths spread across the whole sky far more than red ones."
        let headline = JobSummary.headline(from: answer)
        #expect(headline.count <= JobSummary.headlineLength + 1)
        #expect(headline.hasSuffix("…"))
        #expect(!headline.contains("  "))
        #expect(answer.hasPrefix(String(headline.dropLast())))
    }

    @Test func plainTextOnly() {
        #expect(JobSummary.headline(from: "`config` is **nil** at launch.") == "config is nil at launch.")
    }

    @Test func noWords() {
        #expect(JobSummary.headline(from: "") == "Done.")
    }
}
