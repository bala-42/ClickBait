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

    /// Using ClickBait again while it works sends the work to the dock, whichever key.
    @Test func explainPeelsLikeTheChord() {
        let busy: [PeelRule.Phase] = [.transcribing, .orderCheck, .elementPick, .buildingRequest, .streaming]
        for phase in busy {
            #expect(PeelRule.outcome(of: .explain, in: .init(phase: phase)) == PeelRule.outcome(of: .chord, in: .init(phase: phase)))
        }
        let snipBusy: [PeelRule.Phase] = [.buildingRequest, .streaming, .explained, .partsLook, .tourPrep]
        for phase in snipBusy {
            let situation = PeelRule.Situation(phase: phase, work: .snip)
            #expect(PeelRule.outcome(of: .explain, in: situation) == PeelRule.outcome(of: .chord, in: situation))
        }
        #expect(PeelRule.outcome(of: .explain, in: .init(phase: .streaming)) == .peelNow)
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

struct AutoPeelTests {
    private func auto(_ phase: PeelRule.Phase, _ work: PeelRule.Work, room: Bool = true) -> Bool {
        PeelRule.autoPeels(.init(phase: phase, work: work, hasRoom: room))
    }

    @Test func explanationPeelsOnlyWhileStreaming() {
        #expect(auto(.streaming, .answer))
        for phase: PeelRule.Phase in [.idle, .listening, .buildingRequest, .explained, .tour] {
            #expect(!auto(phase, .answer))
        }
    }

    @Test func snipPeelsUntilItsTourStarts() {
        for phase: PeelRule.Phase in [.streaming, .explained, .partsLook, .tourPrep] {
            #expect(auto(phase, .snip))
            #expect(PeelRule.skipsTourAndSuggestsParts(.init(phase: phase, work: .snip)) == (phase != .streaming))
        }
        #expect(!auto(.tour, .snip))
        #expect(!auto(.buildingRequest, .snip))
    }

    /// Already answered when the user moves on: the answer is in before the peel would start, so the companion stays and no
    /// new one appears at the cursor — for snips too, which otherwise peel until their tour.
    @Test func aFastAnswerNeverPeels() {
        for phase: PeelRule.Phase in [.streaming, .explained, .partsLook, .tourPrep] {
            #expect(!PeelRule.autoPeels(.init(phase: phase, work: .snip), answeredAlready: true))
            #expect(!PeelRule.autoPeels(.init(phase: phase, work: .answer), answeredAlready: true))
        }
        #expect(PeelRule.autoPeels(.init(phase: .explained, work: .snip), answeredAlready: false))  // slow: as before
    }

    @Test func fullDockKeepsItInFront() {
        #expect(!auto(.streaming, .answer, room: false))
        #expect(!auto(.explained, .snip, room: false))
    }
}

struct SnipMatchTests {
    private let side = SnipMatch.side

    private func picture(_ value: (Int, Int) -> Int) -> [UInt8] {
        (0..<side * side).map { UInt8(clamping: value($0 % side, $0 / side)) }
    }

    @Test func samePictureMatches() {
        let stripes = picture { x, _ in x % 4 < 2 ? 30 : 220 }
        #expect(SnipMatch.matches(stripes, stripes))
        #expect(SnipMatch.difference(stripes, stripes) == 0)
    }

    @Test func aBlinkingCaretStillMatches() {
        let page = picture { _, y in y % 6 == 0 ? 40 : 235 }
        var caret = page
        for y in 10..<16 { caret[y * side + 20] = 0 }
        #expect(SnipMatch.matches(page, caret))
    }

    @Test func aScrollDoesNot() {
        let page = picture { _, y in y % 6 < 3 ? 40 : 235 }
        let scrolled = picture { _, y in (y + 3) % 6 < 3 ? 40 : 235 }
        #expect(!SnipMatch.matches(page, scrolled))
    }

    @Test func wrongSizesNeverMatch() {
        #expect(!SnipMatch.matches([1, 2, 3], [1, 2, 3]))
        #expect(SnipMatch.difference([], []) == nil)
    }
}
