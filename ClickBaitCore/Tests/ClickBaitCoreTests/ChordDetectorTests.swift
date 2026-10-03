import Testing
@testable import ClickBaitCore

struct ChordDetectorTests {
    private func run(_ steps: [Step]) -> [ChordDetector.Event] {
        var detector = ChordDetector()
        return steps.flatMap { step -> [ChordDetector.Event] in
            switch step {
            case .mods(let modifiers): detector.modifiersChanged(to: modifiers)
            case .key: detector.keyPressed()
            }
        }
    }

    private enum Step {
        case mods(Modifiers)
        case key
    }

    @Test func askHoldAndRelease() {
        #expect(run([.mods(.control), .mods([.control, .option]), .mods(.option), .mods([])]) == [.askPressed, .askReleased])
    }

    @Test func askCancelledByAnotherKey() {
        #expect(run([.mods([.control, .option]), .key, .mods([])]) == [.askPressed, .askCancelled])
    }

    @Test func askCancelledByAddingCommandOrShift() {
        #expect(run([.mods([.control, .option]), .mods([.control, .option, .shift])]) == [.askPressed, .askCancelled])
    }

    @Test func explainPressAndReleaseInEitherOrder() {
        #expect(run([.mods(.option), .mods([.option, .command]), .mods(.option), .mods([])]) == [.explainPressed, .explainReleased])
        #expect(run([.mods(.command), .mods([.option, .command]), .mods(.command), .mods([])]) == [.explainPressed, .explainReleased])
    }

    @Test func explainCancelledByRealShortcuts() {
        // ⌥⌘D (toggle Dock), ⌥⌘Esc (Force Quit)
        #expect(run([.mods([.option, .command]), .key, .mods(.option), .mods([])]) == [.explainPressed, .explainCancelled])
    }

    @Test func explainCancelledWhenAModifierIsAdded() {
        #expect(run([.mods([.option, .command]), .mods([.option, .command, .shift]), .mods([])]) == [.explainPressed, .explainCancelled])
    }

    @Test func explainOncePerPress() {
        #expect(run([.mods([.option, .command]), .mods(.option), .mods([.option, .command]), .mods([])])
                == [.explainPressed, .explainReleased, .explainPressed, .explainReleased])
    }

    @Test func chordsDoNotTriggerEachOther() {
        // Control+Option+Command is neither chord.
        #expect(run([.mods([.control, .option, .command]), .mods([])]) == [])
        // Holding ⌥ alone does nothing.
        #expect(run([.mods(.option), .mods([])]) == [])
    }
}
