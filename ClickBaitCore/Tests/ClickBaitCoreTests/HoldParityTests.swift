import Testing
@testable import ClickBaitCore

/// Lavender (planning a walkthrough) holds exactly as Strawberry Red (working out a snip) does
/// (user's rule, 2026-10-14). Every rule, every input: the same answer for both.
struct HoldParityTests {
    @Test func theyDockUnderTheSameConditions() {
        for working in [true, false] {
            for answered in [true, false] {
                for room in [true, false] {
                    let red = PeelRule.holdPeels(.snip, stillWorking: working, answeredAlready: answered, hasRoom: room)
                    let lavender = PeelRule.holdPeels(.walkthrough, stillWorking: working, answeredAlready: answered, hasRoom: room)
                    #expect(red == lavender, "working \(working), answered \(answered), room \(room)")
                }
            }
        }
    }

    @Test func stillWorkingWithRoomIsADock() {
        for hold in PeelRule.Hold.allCases {
            #expect(PeelRule.holdPeels(hold, stillWorking: true, hasRoom: true))
            #expect(!PeelRule.holdPeels(hold, stillWorking: true, hasRoom: false))  // a full dock keeps it in front
            #expect(!PeelRule.holdPeels(hold, stillWorking: false, hasRoom: true))  // done already: nothing to send
            #expect(!PeelRule.holdPeels(hold, stillWorking: true, answeredAlready: true, hasRoom: true))  // fast: no new companion
        }
    }

    @Test func neitherPointsNorOpensAppsAndBothRejoinTheCursor() {
        for hold in PeelRule.Hold.allCases {
            #expect(!PeelRule.mayPoint(during: hold))
            #expect(!PeelRule.mayOpenApps(during: hold))
            #expect(PeelRule.rejoinsCursor(after: hold))
        }
    }

    @Test func bothWaitForTheUsersGoOnTheCard() {
        #expect(PeelRule.resumeAction(.snip) == "show me the parts")
        #expect(PeelRule.resumeAction(.walkthrough) == "show me!")
    }

    /// The snip's own auto-peel goes through the shared rule (so the two can't drift apart).
    @Test func theSnipsAutoPeelIsTheSharedRule() {
        for phase: PeelRule.Phase in [.streaming, .explained, .partsLook, .tourPrep, .tour, .buildingRequest] {
            for room in [true, false] {
                let working = [.streaming, .explained, .partsLook, .tourPrep].contains(phase)
                #expect(PeelRule.autoPeels(.init(phase: phase, work: .snip, hasRoom: room))
                        == PeelRule.holdPeels(.snip, stillWorking: working, hasRoom: room))
            }
        }
    }
}
