import AVFoundation
import ClickBaitCore
import Speech

/// Apple's on-device speech recognition (`SpeechAnalyzer`, macOS 26+), offered beside the
/// Whisper models as `SpeechModel.apple`. English (US), like the Whisper models. Its model is
/// an Apple system asset: downloaded once from Apple when the user clicks Download, then
/// recognised on this Mac. Idea from Sentient OS.
@available(macOS 26, *)
enum AppleSpeech {
    static let locale = Locale(identifier: "en_US")

    private static func module() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    /// This Mac can run it (Apple silicon, supported locale).
    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    static func isInstalled() async -> Bool {
        await AssetInventory.status(forModules: [module()]) == .installed
    }

    /// Downloads and installs Apple's model; `progress` gets 0…1.
    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module()]) else { return }
        let observation = request.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    /// Transcribes 16 kHz mono samples, the same input the Whisper path takes.
    static func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let transcriber = module()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Apple speech has no audio format for this Mac."])
        }
        let buffer = try convert(samples, to: format)
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        feed.yield(AnalyzerInput(buffer: buffer))
        feed.finish()
        // Only final results arrive (no volatile ones are asked for); together they're the text.
        let collected = Task {
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        if let end = try await analyzer.analyzeSequence(input) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return TranscriptCleaner.clean(try await collected.value)
    }

    /// 16 kHz mono Float32 into a buffer in `format`, converting when they differ.
    private static func convert(_ samples: [Float], to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else {
            throw CocoaError(.coderInvalidValue)
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if source == format { return input }
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16_000) + 1024) else {
            throw CocoaError(.coderInvalidValue)
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if fed { state.pointee = .endOfStream; return nil }
            fed = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? CocoaError(.coderInvalidValue) }
        return output
    }
}
