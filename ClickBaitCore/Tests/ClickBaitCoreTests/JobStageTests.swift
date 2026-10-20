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
