import Testing
@testable import ClickBaitCore

struct BrightnessStepTests {
    @Test func keysAreTheBrightnessCodes() {
        #expect(BrightnessStep.key(forSystemCode: 2) == .up)
        #expect(BrightnessStep.key(forSystemCode: 3) == .down)
        #expect(BrightnessStep.key(forSystemCode: 0) == nil)  // volume up stays the volume's
    }

    @Test func stepsLikeMacOSAndStayInRange() {
        #expect(BrightnessStep.apply(.up, level: 0.5) == 0.563)
        #expect(BrightnessStep.apply(.down, level: 0.5, fine: true) == 0.484)
        #expect(BrightnessStep.apply(.up, level: 0.98) == 1)
        #expect(BrightnessStep.apply(.down, level: 0.02) == 0)
    }
}
