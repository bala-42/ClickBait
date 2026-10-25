import Foundation
import Testing
@testable import ClickBaitCore

/// Your question first: a dock answer waits to start while one is waiting (2026-10-25).
struct ModelTurnsTests {
    @Test func anAnswerGivesWayOnceInTheDock() {
        let turn = ModelTurn()
        #expect(!turn.isBackground)
        turn.sendToBackground()
        #expect(turn.isBackground)
    }

    @Test func aWaitingQuestionHoldsTheDockBack() async {
        ModelTurns.enter()
        #expect(ModelTurns.foregroundBusy)
        let waited = Task { await ModelTurns.waitForTurn(); return Date() }
        try? await Task.sleep(for: .milliseconds(250))
        let released = Date()
        ModelTurns.leave()
        let turnAt = await waited.value
        #expect(turnAt >= released)
        #expect(!ModelTurns.foregroundBusy)
    }
}
