import Testing
@testable import ClickBaitCore

struct OnboardingTests {
    @Test func pullProgressIsRead() {
        let line = #"{"status":"pulling 4c27e0f5b5ad","digest":"sha256:4c27","total":6600000000,"completed":330000000}"#
        #expect(OllamaSetup.parse(line: line) == .init(status: "pulling 4c27e0f5b5ad", fraction: 0.05))
        #expect(OllamaSetup.parse(line: #"{"status":"verifying sha256 digest"}"#)?.fraction == nil)
        #expect(OllamaSetup.parse(line: #"{"status":"success"}"#)?.isDone == true)
        #expect(OllamaSetup.parse(line: #"{"error":"pull model manifest: file does not exist"}"#)?.status.hasPrefix("error: ") == true)
        #expect(OllamaSetup.parse(line: "not json") == nil)
    }

    @Test func setupCarriesOnWhereItLeftOff() {
        #expect(OnboardingStep.start(welcomed: false, done: []) == .welcome)
        // Reopened after Screen Recording: straight on to the model.
        #expect(OnboardingStep.start(welcomed: true, done: [.microphone, .accessibility, .screenRecording]) == .model)
        #expect(OnboardingStep.start(welcomed: true, done: [.microphone, .accessibility, .screenRecording, .model, .speech]) == .ready)
        #expect(OnboardingStep.ready.next == .ready)
    }
}
