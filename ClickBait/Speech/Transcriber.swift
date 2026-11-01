import ClickBaitCore
import Foundation
@preconcurrency import WhisperKit

enum TranscriberError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notLoaded: "The speech model isn't loaded yet."
        }
    }
}

/// Owns the WhisperKit pipeline. WhisperKit isn't Sendable, so it lives inside this
/// actor and is never handed out.
actor Transcriber {
    private var whisper: WhisperKit?
    private var loadedFolder: URL?
    /// A multilingual model (Large Turbo): the language is detected, not assumed English.
    private var multilingual = false

    /// Loads a model that is already on disk. `download: false` plus a tokenizer that's
    /// already in `tokenizerBase` means this never touches the network.
    func load(modelFolder: URL, tokenizerBase: URL) async throws {
        guard loadedFolder != modelFolder else { return }
        whisper = nil
        loadedFolder = nil

        let config = WhisperKitConfig(
            downloadBase: tokenizerBase,
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerBase,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        whisper = try await WhisperKit(config)
        loadedFolder = modelFolder
        multilingual = !modelFolder.lastPathComponent.contains(".en")
    }

    /// Whisper conditions on up to ~224 tokens; fewer keeps it fast and stops a prompt leaking in.
    private static let maxPromptTokens = 120

    func unload() {
        whisper = nil
        loadedFolder = nil
    }

    /// Transcribes 16 kHz mono samples. Returns an empty string when nothing was said
    /// (Whisper's non-speech labels like `[BLANK_AUDIO]` are stripped). `prompt`: words Whisper
    /// reads as what came before (dictation's screen words), so it spells them the same way.
    func transcribe(_ samples: [Float], prompt: String? = nil) async throws -> String {
        guard let whisper else { throw TranscriberError.notLoaded }
        var promptTokens: [Int]?
        if let prompt, !prompt.isEmpty, let tokenizer = whisper.tokenizer {
            let special = tokenizer.specialTokens.specialTokenBegin
            promptTokens = Array(tokenizer.encode(text: " " + prompt).filter { $0 < special }.suffix(Self.maxPromptTokens))
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: multilingual ? nil : "en",
            temperature: 0,
            detectLanguage: multilingual,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            suppressBlank: true,
            // Whisper's own no-speech filter dropped short, quiet questions; silence is
            // caught before transcribing instead (AudioConditioner).
            noSpeechThreshold: nil
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        return TranscriptCleaner.clean(results.map(\.text).joined(separator: " "))
    }
}
