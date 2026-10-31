import Testing
@testable import ClickBaitCore

struct BrainTests {
    @Test func recommendsTheLargestComfortableBrainButNeverAboveStandard() {
        #expect(Brain.recommended(macMemoryGB: 8) == .light)
        #expect(Brain.recommended(macMemoryGB: 12) == .light)
        #expect(Brain.recommended(macMemoryGB: 16) == .standard)
        #expect(Brain.recommended(macMemoryGB: 24) == .standard)
        #expect(Brain.recommended(macMemoryGB: 64) == .standard)
    }

    @Test func ranksSmallestFirst() {
        #expect(Brain.allCases == [.light, .standard, .big, .galaxy])
    }

    @Test func knowsTheModelsUnderTheirOldNames() {
        #expect(Brain.matching(model: "gemma4:e4b") == .standard)
        #expect(Brain.matching(model: " gemma4:e4b-mlx ") == .standard)
        #expect(Brain.matching(model: "qwen3.5:9b") == .big)
        #expect(Brain.matching(model: "llava") == nil)
        #expect(Brain.standard.isInstalled(in: ["gemma4:e4b", "qwen3.5:9b"]))
        #expect(!Brain.galaxy.isInstalled(in: ["gemma4:e4b"]))
    }

    @Test func saysWhenABrainIsTooBigForThisMac() {
        #expect(Brain.galaxy.fitNote(macMemoryGB: 24) == "this mac has 24 GB, it would be slow")
        #expect(Brain.galaxy.fitNote(macMemoryGB: 8) == "needs 32 GB · too big for this mac")
        #expect(Brain.big.fitNote(macMemoryGB: 8) == "needs 16 GB · too big for this mac")
        #expect(Brain.standard.fitNote(macMemoryGB: 24) == nil)
    }
}
