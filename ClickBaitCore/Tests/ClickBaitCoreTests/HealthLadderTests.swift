import Testing
@testable import ClickBaitCore

struct HealthLadderTests {
    @Test func worstComesFirst() {
        let off = ["Screen Recording", "Microphone"]
        #expect(HealthLadder.worst(model: .unreachable, permissionsOff: off) == .ollamaOff)
        #expect(HealthLadder.worst(model: .missing("qwen3.5:9b"), permissionsOff: off) == .modelMissing("qwen3.5:9b"))
        #expect(HealthLadder.worst(model: .ready, permissionsOff: off) == .permissionOff("Screen Recording"))
        #expect(HealthLadder.worst(model: .asleep, permissionsOff: off) == .permissionOff("Screen Recording"))
        #expect(HealthLadder.worst(model: nil, permissionsOff: off) == .permissionOff("Screen Recording"))
        #expect(HealthLadder.worst(model: .asleep, permissionsOff: []) == .modelAsleep)
        #expect(HealthLadder.worst(model: .ready, permissionsOff: []) == .ready)
        #expect(HealthLadder.worst(model: nil, permissionsOff: []) == nil)  // still checking
    }

    @Test func onlyRealProblemsAskForAction() {
        #expect(HealthLadder.Item.ollamaOff.isProblem)
        #expect(HealthLadder.Item.permissionOff("Accessibility").isProblem)
        #expect(!HealthLadder.Item.modelAsleep.isProblem)
        #expect(!HealthLadder.Item.ready.isProblem)
    }
}
