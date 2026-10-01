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
    }

    func unload() {
        whisper = nil
        loadedFolder = nil
    }

    /// Transcribes 16 kHz mono samples. Returns an empty string when nothing was said
    /// (Whisper's non-speech labels like `[BLANK_AUDIO]` are stripped).
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let whisper else { throw TranscriberError.notLoaded }
        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        return TranscriptCleaner.clean(results.map(\.text).joined(separator: " "))
    }
}
