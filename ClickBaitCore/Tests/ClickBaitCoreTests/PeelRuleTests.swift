import Testing
@testable import ClickBaitCore

struct PeelRuleTests {
    private func chord(_ phase: PeelRule.Phase, _ work: PeelRule.Work = .answer,
                       kind: PeelRule.Kind = .unknown, room: Bool = true) -> PeelRule.Outcome {
        PeelRule.outcome(of: .chord, in: .init(phase: phase, work: work, kind: kind, hasRoom: room))
    }

    @Test func idleJustStartsANewOne() {
        #expect(chord(.idle) == .startNew)
        #expect(PeelRule.outcome(of: .explain, in: .init(phase: .idle)) == .startNew)
    }

    @Test func listeningIsAlreadyListening() {
        #expect(chord(.listening) == .ignore(.alreadyListening))
        #expect(chord(.listening, room: false) == .ignore(.alreadyListening))
        #expect(PeelRule.outcome(of: .explain, in: .init(phase: .listening)) == .ignore(.alreadyListening))
    }

    @Test func tableOfOutcomesForEveryPhaseAndWork() {
        typealias P = PeelRule.Phase
        let table: [(P, PeelRule.Work, PeelRule.Outcome, PeelRule.Outcome)] = [
            // phase, work, with room, without room
            (.transcribing, .answer, .peelWhenReady, .ignore(.threesACrowd)),
            (.orderCheck, .answer, .peelWhenReady, .ignore(.threesACrowd)),
            (.elementPick, .answer, .peelWhenReady, .ignore(.threesACrowd)),
            (.buildingRequest, .answer, .peelWhenReady, .ignore(.threesACrowd)),
            (.streaming, .answer, .peelNow, .ignore(.threesACrowd)),
            (.explained, .answer, .startNew, .startNew),
            (.partsLook, .answer, .startNew, .startNew),
            (.tourPrep, .answer, .startNew, .startNew),
            (.tour, .answer, .startNew, .startNew),
            (.buildingRequest, .snip, .peelWhenReady, .ignore(.threesACrowd)),
            (.streaming, .snip, .peelNow, .ignore(.threesACrowd)),
            (.explained, .snip, .peelNow, .ignore(.threesACrowd)),
            (.partsLook, .snip, .peelNow, .ignore(.threesACrowd)),
            (.tourPrep, .snip, .peelNow, .ignore(.threesACrowd)),
            (.tour, .snip, .startNew, .startNew),
        ]
        for (phase, work, withRoom, noRoom) in table {
            #expect(chord(phase, work) == withRoom, "\(phase) \(work) with room")
            #expect(chord(phase, work, room: false) == noRoom, "\(phase) \(work) without room")
        }
    }

    @Test func aKnownQuickKindIsTooQuickInAnyPreRunPhaseEvenWithAFullDock() {
        for phase in [PeelRule.Phase.transcribing, .orderCheck, .elementPick, .buildingRequest] {
            for kind in [PeelRule.Kind.command, .instantPick] {
                #expect(chord(phase, kind: kind) == .tooQuick)
                #expect(chord(phase, kind: kind, room: false) == .tooQuick)
            }
        }
    }

    @Test func anUnknownOrModelKindInTheElementPickStillQueues() {
        #expect(chord(.elementPick, kind: .unknown) == .peelWhenReady)
        #expect(chord(.elementPick, kind: .modelAnswer) == .peelWhenReady)
    }

    @Test func aSnipInPartsLookKeepsItsExplanationAndSuggestsTheParts() {
        func skips(_ phase: PeelRule.Phase, _ work: PeelRule.Work) -> Bool {
            PeelRule.skipsTourAndSuggestsParts(.init(phase: phase, work: work))
        }
        #expect(skips(.explained, .snip))
        #expect(skips(.partsLook, .snip))
        #expect(skips(.tourPrep, .snip))
        #expect(!skips(.tour, .snip))
        #expect(!skips(.streaming, .snip))
        #expect(!skips(.explained, .answer))
        #expect(PeelRule.suggestedPartsPrompt == "show me the parts")
    }

    @Test func explainNeverPeelsAndSaysBusyOtherwise() {
        let busy: [PeelRule.Phase] = [.transcribing, .orderCheck, .elementPick, .buildingRequest, .streaming]
        for phase in busy {
            #expect(PeelRule.outcome(of: .explain, in: .init(phase: phase)) == .ignore(.busy))
        }
        let snipBusy: [PeelRule.Phase] = [.buildingRequest, .streaming, .explained, .partsLook, .tourPrep]
        for phase in snipBusy {
            #expect(PeelRule.outcome(of: .explain, in: .init(phase: phase, work: .snip)) == .ignore(.busy))
        }
    }

    @Test func explainStillWorksDuringPointingAndTours() {
        for phase: PeelRule.Phase in [.explained, .partsLook, .tourPrep, .tour] {
            #expect(PeelRule.outcome(of: .explain, in: .init(phase: phase)) == .startNew)
        }
        #expect(PeelRule.outcome(of: .explain, in: .init(phase: .tour, work: .snip)) == .startNew)
    }

    @Test func reasonsReadAsLogLines() {
        #expect(PeelRule.Reason.alreadyListening.logText == "already listening")
        #expect(PeelRule.Reason.threesACrowd.logText == "three's a crowd")
        #expect(PeelRule.Reason.busy.logText == "busy")
    }

    // MARK: Endings

    @Test func aModelAnswerJoinsTheTile() {
        let resolution = PeelRule.resolution(of: .modelAnswer)
        #expect(resolution == .joinTile)
        #expect(!resolution.removesTile)
        #expect(resolution.pill == nil)
    }

    @Test func aCommandRunsAndTheTileGoes() {
        let resolution = PeelRule.resolution(of: .command)
        #expect(resolution == .runCommand)
        #expect(resolution.removesTile)
        #expect(resolution.pill == "that one was quick — nothing to send away")
    }

    @Test func anInstantPickPointsOrGivesAGoThereResult() {
        let free = PeelRule.resolution(of: .instantPick(foregroundBusy: false))
        let busy = PeelRule.resolution(of: .instantPick(foregroundBusy: true))
        #expect(free == .pointNow)
        #expect(busy == .goThereResult)
        #expect(free.removesTile && busy.removesTile)
        #expect(free.pill == PeelRule.quickPill && busy.pill == PeelRule.quickPill)
    }

    // MARK: Queue to ending

    @Test func aQueuedPeelEndsAsEachEndingResolves() {
        let queued = chord(.orderCheck)
        #expect(queued == .peelWhenReady)
        #expect(PeelRule.resolution(of: .modelAnswer) == .joinTile)
        for ending in [PeelRule.Ending.command, .instantPick(foregroundBusy: false),
                       .instantPick(foregroundBusy: true)] {
            let resolution = PeelRule.resolution(of: ending)
            #expect(resolution.removesTile)
            #expect(resolution.pill == PeelRule.quickPill)
        }
    }

    // MARK: A queued peel never loses the answer

    @Test func aJobMadeAtQueueTimeKeepsTheWholeAnswer() {
        // Queued: the job exists before any run does.
        var job = BackgroundJob(question: "Why is the sky blue?", kind: .answer, homeBundleID: nil,
                                homePID: nil, conversation: Conversation())
        #expect(job.isWorking && job.answer.isEmpty)
        // Later the run joins and streams.
        job.append("Blue light ")
        job.append("scatters most.")
        var conversation = Conversation()
        conversation.append(user: "Why is the sky blue?", assistantSpeech: "Blue light scatters most.")
        job.complete(answer: "Blue light scatters most.", conversation: conversation)
        #expect(job.status == .done(summary: "Blue light scatters most."))
        #expect(job.answer == "Blue light scatters most.")
        #expect(job.conversation.lastAnswer == "Blue light scatters most.")
    }
}
