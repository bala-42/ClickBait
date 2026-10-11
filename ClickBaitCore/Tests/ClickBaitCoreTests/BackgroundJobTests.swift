import Testing
@testable import ClickBaitCore

struct BackgroundJobTests {
    private func job() -> BackgroundJob {
        BackgroundJob(question: "Why is the sky blue?", kind: .answer, homeBundleID: "com.apple.Safari",
                      homePID: 42, conversation: Conversation())
    }

    @Test func startsWorkingWithNoAnswer() {
        let job = job()
        #expect(job.isWorking)
        #expect(job.answer.isEmpty)
    }

    @Test func collectsStreamedTextWhileWorking() {
        var job = job()
        job.append("Light ")
        job.append("scatters.")
        #expect(job.answer == "Light scatters.")
    }

    @Test func completesWithASummaryAndTheConversation() {
        var job = job()
        var conversation = Conversation()
        conversation.append(user: "Why is the sky blue?", assistantSpeech: "Blue light scatters most.")
        job.complete(answer: "Blue light scatters most.", conversation: conversation)
        #expect(job.status == .done(summary: "Blue light scatters most."))
        #expect(job.conversation.lastAnswer == "Blue light scatters most.")
    }

    @Test func onlyAWorkingJobChanges() {
        var job = job()
        job.stop()
        job.append("late text")
        job.fail("too late")
        job.complete(answer: "too late", conversation: Conversation())
        #expect(job.status == .stopped)
        #expect(job.answer.isEmpty)
    }

    @Test func failingKeepsTheReason() {
        var job = job()
        job.fail("Ollama isn't running")
        #expect(job.status == .failed(reason: "Ollama isn't running"))
        #expect(!job.isWorking)
    }
}

struct JobSummaryTests {
    @Test func emptyAnswerIsDone() {
        #expect(JobSummary.make(from: "  \n ") == "Done.")
    }

    @Test func keepsTheFirstTwoSentences() {
        let summary = JobSummary.make(from: "Blue light scatters most. Red passes through. Sunsets look red.")
        #expect(summary == "Blue light scatters most. Red passes through.")
    }

    @Test func longSummariesAreCutAtAWord() {
        let long = String(repeating: "scattering ", count: 30) + "ends."
        let summary = JobSummary.make(from: long)
        #expect(summary.count <= JobSummary.maxLength)
        #expect(summary.hasSuffix("…"))
        #expect(!summary.dropLast().hasSuffix(" "))
    }
}

struct LiveLineTests {
    @Test func beforeAnyWordsItSaysItsWorking() {
        #expect(JobSummary.liveLine(from: "") == "working on it…")
    }

    @Test func showsTheSentenceBeingWritten() {
        #expect(JobSummary.liveLine(from: "Blue light scatters most. Red passes thro") == "Red passes thro")
        #expect(JobSummary.liveLine(from: "Blue light scatters most.") == "Blue light scatters most.")
    }

    @Test func longSentencesStopAtAWord() {
        let long = String(repeating: "scattering ", count: 20)
        let line = JobSummary.liveLine(from: long)
        #expect(line.count <= JobSummary.liveLength)
        #expect(line.hasSuffix("scattering…"))
    }
}

struct CapsuleLayoutTests {
    private let visible = Rect(x: 0, y: 0, width: 1440, height: 875)

    @Test func slotsStackDownFromTheTopRight() {
        let first = CapsuleLayout.slot(0, in: visible)
        let second = CapsuleLayout.slot(1, in: visible)
        #expect(first?.maxX == 1440 - CapsuleLayout.rightInset)
        #expect(first?.maxY == 875 - CapsuleLayout.topInset)
        #expect(second.map { $0.maxY } == first.map { $0.minY - CapsuleLayout.gap })
    }

    @Test func onlyThreeSlots() {
        #expect(CapsuleLayout.slot(-1, in: visible) == nil)
        #expect(CapsuleLayout.slot(2, in: visible) != nil)
        #expect(CapsuleLayout.slot(3, in: visible) == nil)
    }

    @Test func slotsFollowADisplayWithANegativeOrigin() {
        let left = Rect(x: -1920, y: 0, width: 1920, height: 1055)
        #expect(CapsuleLayout.slot(0, in: left)?.maxX == -CapsuleLayout.rightInset)
    }

    @Test func cardHangsUnderItsCapsuleAndStaysOnScreen() {
        guard let slot = CapsuleLayout.slot(0, in: visible) else { Issue.record("no slot"); return }
        let card = CapsuleLayout.card(under: slot, height: 200, in: visible)
        #expect(card.maxY == slot.minY - CapsuleLayout.cardGap)
        #expect(card.maxX <= visible.maxX - 8)
        #expect(card.width == CapsuleLayout.cardWidth)
        #expect(card.height == 200)
    }

    @Test func tallCardIsClippedToTheScreen() {
        guard let slot = CapsuleLayout.slot(2, in: visible) else { Issue.record("no slot"); return }
        let card = CapsuleLayout.card(under: slot, height: 5000, in: visible)
        #expect(card.minY >= visible.minY + 8)
        #expect(card.maxY <= slot.minY - CapsuleLayout.cardGap)
    }
}
