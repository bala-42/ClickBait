import Foundation
import Testing
@testable import ClickBaitCore

/// Acceptance tests for the background-agent handoff, end to end in Core terms: when it
/// starts (timing), what is on screen at each moment (visibility), the job's states (the
/// same card throughout), and the fallback when the flight can't run.
struct PeelHandoffTests {
    private let cursor = Point(x: 300, y: 400), slot = Point(x: 1400, y: 900)

    // MARK: Timing

    @Test func handoffStartsAfterPointEightSeconds() {
        let peelAt = Double(PeelRule.autoPeelDelay.components.attoseconds) / 1e18
            + Double(PeelRule.autoPeelDelay.components.seconds)
        #expect(abs(peelAt - 0.8) < 1e-9)
        // The fresh companion is fully back at the cursor this soon after the peel starts…
        let freshBack = AgentDock.freshCompanionDelay(.flight) + AgentDock.popTime
        #expect(peelAt + freshBack <= 1.15)
        // …and the copy is in its tile within 1.5 s of the question starting to think.
        #expect(peelAt + AgentDock.growTime + AgentDock.flightTime <= 1.5)
    }

    @Test func freshCompanionNeverOverlapsTheGrowingCopy() {
        // Hidden while the copy grows in its place, then popping in as the copy leaves.
        for t in stride(from: 0.0, to: AgentDock.growTime, by: 0.01) {
            #expect(AgentDock.spawn(at: t, from: cursor, to: slot).freshScale == 0)
            #expect(AgentDock.spawn(at: t, from: cursor, to: slot).center == cursor)
        }
        #expect(AgentDock.freshCompanionDelay(.flight) == AgentDock.growTime)
    }

    // MARK: Visibility

    @Test func copyStaysVisibleUntilItReachesItsTile() {
        let total = AgentDock.growTime + AgentDock.flightTime
        let fading = AgentDock.spawn(at: AgentDock.copyFadeStart * total, from: cursor, to: slot)
        // When the fade starts the copy is already over its tile (within centre-to-corner of
        // the tile; measured 16.6 pt on this 1200 pt trip), small and nearly upright.
        let dx = fading.center.x - slot.x, dy = fading.center.y - slot.y
        #expect((dx * dx + dy * dy).squareRoot() <= AgentDock.tileSize / 2 * 2.0.squareRoot())
        #expect(fading.scale <= 1)
        #expect(abs(fading.angle) < 2)
        #expect(fading.tileOpacity == 1)  // the tile is there to take over
    }

    @Test func tileIsInPlaceBeforeTheCopyArrives() {
        let tileReady = AgentDock.growTime + AgentDock.flightTime * AgentDock.tileShare
        let frame = AgentDock.spawn(at: tileReady, from: cursor, to: slot)
        #expect(frame.tileOpacity == 1 && !frame.docked)
        #expect(AgentDock.slide(at: tileReady) == 1)
    }

    // MARK: Fallback

    @Test func flightOnlyWhenEverythingIsThere() {
        #expect(AgentDock.peelMotion(reduceMotion: false, hasSlot: true, sameDisplay: true) == .flight)
        #expect(AgentDock.peelMotion(reduceMotion: true, hasSlot: true, sameDisplay: true) == .inPlace)
        #expect(AgentDock.peelMotion(reduceMotion: false, hasSlot: false, sameDisplay: true) == .inPlace)
        #expect(AgentDock.peelMotion(reduceMotion: false, hasSlot: true, sameDisplay: false) == .inPlace)
        #expect(AgentDock.peelMotion(reduceMotion: false, hasSlot: true, sameDisplay: true, canAnimate: false) == .inPlace)
    }

    @Test func fallbackBringsTheCompanionBackAtOnce() {
        #expect(AgentDock.freshCompanionDelay(.inPlace) == 0)
    }

    // MARK: State transitions: the same card throughout

    @Test func theJobIsOneCardFromPeelToResult() {
        var job = BackgroundJob(question: "your question", kind: .snip, homeBundleID: "com.apple.Safari",
                                homePID: 42, conversation: Conversation())
        let id = job.id
        #expect(job.isWorking)
        job.rename("what is this diagram")  // heard after it was sent away
        job.append("It shows ")
        job.append("a heat pump.")
        #expect(job.id == id && job.isWorking && job.answer == "It shows a heat pump.")
        job.complete(answer: "It shows a heat pump.", conversation: Conversation())
        #expect(job.id == id && job.question == "what is this diagram")
        #expect(job.status == .done(summary: "It shows a heat pump."))
        job.append("late words")  // nothing changes a finished card
        #expect(job.answer == "It shows a heat pump.")
    }

    @Test func peelingNeverChangesWhatIsAnswered() {
        // Which phases send work away is decided by the rule alone; the motion is cosmetic.
        for motion in [AgentDock.PeelMotion.flight, .inPlace] {
            #expect(PeelRule.autoPeels(.init(phase: .streaming, work: .answer)))
            #expect(AgentDock.freshCompanionDelay(motion) >= 0)
        }
    }
}
