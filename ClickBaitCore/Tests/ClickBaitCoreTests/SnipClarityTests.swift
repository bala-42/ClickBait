import Foundation
import Testing
@testable import ClickBaitCore

/// A small circle on a 1× external display was enlarged ~4.6× and the model guessed (2026-10-25).
struct SnipClarityTests {
    @Test func standardResolutionDisplaysCropWider() {
        #expect(SnipLayout.minSide(pixelsPerPoint: 2) == SnipLayout.minCropSide)  // Retina: as before
        #expect(SnipLayout.minSide(pixelsPerPoint: 1) > 420)  // 1×: ≤ 3× enlargement
        let crop = SnipLayout.crop(around: Rect(x: 500, y: 300, width: 135, height: 145), displayWidth: 1920, displayHeight: 1080,
                                   minSide: SnipLayout.minSide(pixelsPerPoint: 1))
        #expect(crop.width >= 1280 / 3 && crop.height >= 1280 / 3)
    }

    @Test func theModelIsToldWhatWasMarkedAndItsWords() {
        var request = AskRequest(question: "", screenshotJPEG: Data([1]), screenshotWidth: 1280, screenshotHeight: 1280,
                                 context: ScreenContext(appName: "Google Chrome"))
        request.snip = .circled
        request.snipMarked = Rect(x: 400, y: 420, width: 400, height: 430)
        request.snipWords = "Introducing MuseYard"
        let text = Prompt.userText(for: request)
        #expect(text.contains("They marked the part from x 400"))
        #expect(text.contains("Introducing MuseYard"))
        #expect(text.contains("never guess"))
    }
}
