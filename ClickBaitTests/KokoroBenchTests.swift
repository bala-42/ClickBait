import AVFoundation
import Foundation
import Testing
@testable import ClickBait

/// Kokoro's speed on this Mac, and a sample to listen to. Opt-in (needs the downloaded model):
/// `TEST_RUNNER_CLICKBAIT_KOKORO_BENCH=1 xcodebuild test … -only-testing:ClickBaitTests/KokoroBenchTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_KOKORO_BENCH"] == "1"))
struct KokoroBenchTests {
    @Test func timesASentence() async throws {
        #expect(KokoroVoice.isInstalled)
        let start = ContinuousClock.now
        await KokoroEngine.shared.loadIfInstalled()
        print("KOKORO load \(ContinuousClock.now - start)")
        let sentences = ["I found a picture of a man hugging a white dog in your Downloads folder. Want me to open it?",
                         "Share's up here, next to the address bar.",
                         "Kubernetes runs containers across many machines, while Docker Compose runs them on one."]
        for (index, sentence) in sentences.enumerated() {
            let begin = ContinuousClock.now
            let samples = try #require(await KokoroEngine.shared.audio(for: sentence, voice: "af_heart", speed: 1))
            let took = ContinuousClock.now - begin
            let seconds = Double(samples.count) / 24_000
            print("KOKORO \(String(format: "%.1f", seconds)) s of speech in \(took)")
            let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
            let file = try AVAudioFile(forWriting: URL(fileURLWithPath: "/tmp/kokoro-\(index).caf"), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
    }
}
