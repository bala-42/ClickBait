import AVFoundation
import Foundation
@preconcurrency import KokoroSwift
@preconcurrency import MLX
import MLXUtilsLibrary
import Observation

/// Kokoro (user's ask, 2026-11-01): a natural neural voice for spoken answers, on this Mac
/// (82M parameters, MLX). Its voices sit in Settings' Voice picker as "kokoro:<name>"; the
/// model (327 MB) and voices (15 MB) download only when the user clicks Download.
enum KokoroVoice {
    static let prefix = "kokoro:"

    /// The picker's Kokoro voices, best first ("a…" American, "b…" British; f/m).
    static let offered: [(id: String, title: String)] = [
        ("af_heart", "Heart — American, warm"), ("af_bella", "Bella — American"), ("af_nicole", "Nicole — American, soft"),
        ("am_michael", "Michael — American"), ("am_fenrir", "Fenrir — American, deep"), ("am_puck", "Puck — American, bright"),
        ("bf_emma", "Emma — British"), ("bf_isabella", "Isabella — British"), ("bm_george", "George — British"),
        ("bm_fable", "Fable — British, storyteller"),
    ]

    static func name(in identifier: String?) -> String? {
        guard let identifier, identifier.hasPrefix(prefix) else { return nil }
        return String(identifier.dropFirst(prefix.count))
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ClickBait/Kokoro", directoryHint: .isDirectory)
    }
    static var modelFile: URL { folder.appending(path: "kokoro-v1_0.safetensors") }
    static var voicesFile: URL { folder.appending(path: "voices.npz") }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelFile.path) && FileManager.default.fileExists(atPath: voicesFile.path)
    }

    static let downloads: [(URL, URL)] = [
        (URL(string: "https://github.com/mlalma/KokoroTestApp/raw/main/Resources/voices.npz")!, voicesFile),
        (URL(string: "https://media.githubusercontent.com/media/mlalma/KokoroTestApp/main/Resources/kokoro-v1_0.safetensors")!, modelFile),
    ]
}

/// The Settings download: progress, and loading the engine once it's there.
@MainActor
@Observable
final class KokoroDownload {
    static let shared = KokoroDownload()
    private(set) var fraction: Double?
    private(set) var problem: String?

    func start() {
        guard fraction == nil else { return }
        fraction = 0
        problem = nil
        Task {
            do {
                try FileManager.default.createDirectory(at: KokoroVoice.folder, withIntermediateDirectories: true)
                for (index, (source, target)) in KokoroVoice.downloads.enumerated() where !FileManager.default.fileExists(atPath: target.path) {
                    let (temporary, response) = try await URLSession.shared.download(from: source, delegate: Progress { part in
                        Task { @MainActor in KokoroDownload.shared.fraction = (Double(index) * 0.05) + part * (index == 0 ? 0.05 : 0.95) }
                    })
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temporary, to: target)
                }
                await KokoroEngine.shared.warmUp(voice: "af_heart")
            } catch {
                problem = "Couldn't download Kokoro: \(error.localizedDescription)"
            }
            fraction = nil
        }
    }

    private final class Progress: NSObject, URLSessionDownloadDelegate, Sendable {
        let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}

/// Owns the Kokoro model (not Sendable): loaded once, then turns sentences into 24 kHz audio.
actor KokoroEngine {
    static let shared = KokoroEngine()
    private var tts: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    var isLoaded: Bool { tts != nil }

    func loadIfInstalled() {
        guard tts == nil, KokoroVoice.isInstalled else { return }
        let start = ContinuousClock.now
        tts = KokoroTTS(modelPath: KokoroVoice.modelFile)
        voices = NpyzReader.read(fileFromPath: KokoroVoice.voicesFile) ?? [:]
        Log.app.notice("Kokoro loaded in \(String(describing: ContinuousClock.now - start), privacy: .public) (\(self.voices.count, privacy: .public) voices)")
    }

    /// Loads and says one word silently: the first sentence took 4.5 s cold, 0.5 s warm
    /// (measured 2026-11-01, `KokoroBenchTests`).
    func warmUp(voice: String) {
        loadIfInstalled()
        _ = audio(for: "Hi.", voice: voice, speed: 1)
    }

    /// Samples at `KokoroTTS.Constants.samplingRate`, or nil (not loaded, unknown voice, failed).
    func audio(for text: String, voice: String, speed: Float) -> [Float]? {
        guard let tts, let style = voices[voice + ".npy"] else { return nil }
        let start = ContinuousClock.now
        guard let (samples, _) = try? tts.generateAudio(voice: style, language: voice.hasPrefix("a") ? .enUS : .enGB,
                                                        text: text, speed: speed) else { return nil }
        let seconds = Double(samples.count) / Double(KokoroTTS.Constants.samplingRate)
        Log.app.notice("Kokoro: \(String(format: "%.1f", seconds), privacy: .public) s of speech in \(String(describing: ContinuousClock.now - start), privacy: .public)")
        return samples
    }
}
