import AVFoundation
import Foundation
import Testing
@preconcurrency import WhisperKit

/// Whisper models compared on the same spoken sentences (macOS voices, `say`): word error
/// rate and time per sentence. Opt-in, it downloads models:
/// `TEST_RUNNER_CLICKBAIT_SPEECH_BENCH=1 xcodebuild test … -only-testing:ClickBaitTests/SpeechBenchTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_SPEECH_BENCH"] == "1"))
struct SpeechBenchTests {
    static let sentences: [(voice: String, text: String)] = [
        ("Samantha", "Where is the share button in Safari"),
        ("Daniel", "Remind me to call Mum at six tomorrow evening"),
        ("Karen", "Find that note about the plumber coming on Thursday"),
        ("Rishi", "Open System Settings and turn on Night Shift"),
        ("Samantha", "Explain what this Python error means and how to fix it"),
        ("Daniel", "Set the volume to thirty percent"),
        ("Karen", "How do I clear my browsing history in Google Chrome"),
        ("Rishi", "Show me the picture of the airport from last March"),
        ("Samantha", "Summarise this article in three bullet points"),
        ("Daniel", "What's the difference between Kubernetes and Docker Compose"),
        ("Rishi", "Send the invoice PDF to Priya over AirDrop"),
        ("Karen", "Turn this paragraph into a polite email to my landlord"),
    ]
    static let models = ["openai_whisper-small.en", "openai_whisper-large-v3-v20240930_turbo_632MB"]

    @Test func compareWhisperModels() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "speech-bench")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var clips: [[Float]] = []
        for (index, sentence) in Self.sentences.enumerated() {
            let file = dir.appending(path: "\(index).wav")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", sentence.voice, "-o", file.path, "--data-format=LEF32@16000", sentence.text]
            try say.run()
            say.waitUntilExit()
            let audio = try AVAudioFile(forReading: file)
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
            try audio.read(into: buffer)
            clips.append(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
        }
        let base = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/clickbait-speech-bench")
        for model in Self.models {
            let loadStart = ContinuousClock.now
            let whisper = try await WhisperKit(WhisperKitConfig(model: model, downloadBase: base, verbose: false, logLevel: .none,
                                                                prewarm: true, load: true, download: true))
            let loaded = ContinuousClock.now - loadStart
            var errors = 0, words = 0
            var total: Duration = .zero
            for (index, clip) in clips.enumerated() {
                let start = ContinuousClock.now
                let options = DecodingOptions(language: "en", temperature: 0, skipSpecialTokens: true, withoutTimestamps: true)
                let heard = try await whisper.transcribe(audioArray: clip, decodeOptions: options).map(\.text).joined(separator: " ")
                total += ContinuousClock.now - start
                let expected = Self.words(Self.sentences[index].text)
                errors += Self.distance(expected, Self.words(heard))
                words += expected.count
                print("[\(model)] \(heard.trimmingCharacters(in: .whitespaces))")
            }
            print("BENCH \(model): WER \(String(format: "%.1f", 100 * Double(errors) / Double(words)))% · \(total / clips.count) per sentence · load \(loaded)")
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Word-level edit distance.
    static func distance(_ a: [String], _ b: [String]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }
}
