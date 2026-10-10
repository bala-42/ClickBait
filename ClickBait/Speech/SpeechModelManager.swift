import ClickBaitCore
import Foundation
import Observation
@preconcurrency import WhisperKit

/// The Whisper models offered in Settings. English-only variants are faster and more
/// accurate for English than the multilingual ones of the same size.
enum SpeechModel: String, CaseIterable, Identifiable {
    case tinyEnglish = "tiny.en"
    case baseEnglish = "base.en"
    case smallEnglish = "small.en"

    static let `default`: SpeechModel = .baseEnglish

    var id: String { rawValue }

    /// Where WhisperKit stores this model's tokenizer under the download base.
    var tokenizerPath: String { "models/openai/whisper-\(rawValue)/tokenizer.json" }

    var displayName: String {
        switch self {
        case .tinyEnglish: "Tiny (English, ~75 MB) — fastest"
        case .baseEnglish: "Base (English, ~145 MB) — recommended"
        case .smallEnglish: "Small (English, ~480 MB) — most accurate"
        }
    }
}

/// Downloads (only when the user asks), finds and loads the on-device speech model.
///
/// Privacy: the download from Hugging Face is the only network call this makes, and it
/// only happens from `download()`, which is wired to explicit buttons. `importModel(from:)`
/// never touches the network: it's how a Mac without internet finishes setup. Loading refuses
/// to run unless the model *and* its tokenizer are already on disk, because WhisperKit
/// would otherwise quietly fetch a missing tokenizer.
@MainActor
@Observable
final class SpeechModelManager {
    enum State: Equatable {
        case notDownloaded
        case downloading(fraction: Double)
        case importing
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private var work: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        state = installedFolder(for: settings.speechModel) == nil ? .notDownloaded : .loading
    }

    var isReady: Bool { state == .ready }

    static var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "ClickBait/SpeechModels", directoryHint: .isDirectory)
    }

    /// Loads the selected model if it's already downloaded. Never downloads.
    func loadIfInstalled() {
        let model = settings.speechModel
        guard let folder = installedFolder(for: model) else {
            state = .notDownloaded
            Task { await transcriber.unload() }
            return
        }
        work?.cancel()
        state = .loading
        work = Task {
            do {
                let start = ContinuousClock.now
                try await transcriber.load(modelFolder: folder, tokenizerBase: Self.baseDirectory)
                guard settings.speechModel == model else { return }
                state = .ready
                Log.app.notice("Speech model \(model.rawValue, privacy: .public) loaded in \(String(describing: ContinuousClock.now - start), privacy: .public)")
            } catch {
                state = .failed("Couldn't load the speech model: \(error.localizedDescription)")
                Log.app.error("Speech model load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Downloads the selected model and its tokenizer from Hugging Face. Only call this
    /// in response to the user clicking a Download button.
    func download() {
        if case .downloading = state { return }
        let model = settings.speechModel
        work?.cancel()
        state = .downloading(fraction: 0)
        Log.app.notice("User started speech model download: \(model.rawValue, privacy: .public)")

        let reportProgress: ProgressCallback = { [weak self] progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.updateDownloadProgress(fraction) }
        }
        work = Task {
            do {
                let base = Self.baseDirectory
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let folder = try await WhisperKit.download(
                    variant: model.rawValue,
                    downloadBase: base,
                    progressCallback: reportProgress
                )
                settings.setSpeechModelFolder(folder, for: model)

                // A first load with download allowed fetches the matching tokenizer into
                // `base`, so later loads (download: false) find it locally.
                _ = try await WhisperKit(WhisperKitConfig(
                    downloadBase: base,
                    modelFolder: folder.path,
                    tokenizerFolder: base,
                    verbose: false,
                    logLevel: .none,
                    load: true,
                    download: true
                ))
                guard Self.hasTokenizer(for: model) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The tokenizer didn't download."])
                }
                Log.app.notice("Speech model download finished: \(model.rawValue, privacy: .public)")
                loadIfInstalled()
            } catch is CancellationError {
                state = .notDownloaded
            } catch {
                state = .failed("Download failed: \(error.localizedDescription)")
                Log.app.error("Speech model download failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Copies a model the user picked (the SpeechModels folder from another Mac, a model
    /// folder with its tokenizer, or a .zip of either) to where downloads go, after checking
    /// it's complete (`SpeechModelImport`), then switches to it and loads it. Local only.
    func importModel(from source: URL) {
        if case .downloading = state { return }
        guard state != .importing else { return }
        work?.cancel()
        state = .importing
        let preferred = settings.speechModel.rawValue
        let variants = SpeechModel.allCases.map(\.rawValue)
        let base = Self.baseDirectory
        Log.app.notice("User started speech model import (\(source.pathExtension.lowercased() == "zip" ? "zip" : "folder", privacy: .public))")
        work = Task {
            do {
                let start = ContinuousClock.now
                let variant = try await Task.detached(priority: .userInitiated) {
                    try SpeechModelImport.install(from: source, into: base, variants: variants, preferred: preferred)
                }.value
                guard let model = SpeechModel(rawValue: variant) else { return }
                settings.setSpeechModelFolder(base.appending(path: SpeechModelImport.destination(for: variant).model,
                                                             directoryHint: .isDirectory), for: model)
                Log.app.notice("Speech model \(variant, privacy: .public) imported in \(String(describing: ContinuousClock.now - start), privacy: .public)")
                // Switching the picker to it loads it too (Settings' onChange); loading twice is a no-op.
                if settings.speechModel != model { settings.speechModel = model }
                loadIfInstalled()
            } catch is CancellationError {
                state = installedFolder(for: settings.speechModel) == nil ? .notDownloaded : .ready
            } catch {
                state = .failed(error is SpeechModelImportError ? error.localizedDescription
                                : "Import failed: \(error.localizedDescription)")
                Log.app.error("Speech model import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateDownloadProgress(_ fraction: Double) {
        guard case .downloading = state else { return }
        // Reserve the last few percent for the tokenizer + first load.
        state = .downloading(fraction: fraction * 0.95)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcriber.transcribe(samples)
    }

    private func installedFolder(for model: SpeechModel) -> URL? {
        guard let folder = settings.speechModelFolder(for: model) else { return nil }
        let encoder = folder.appending(path: "AudioEncoder.mlmodelc")
        guard FileManager.default.fileExists(atPath: encoder.path), Self.hasTokenizer(for: model) else {
            return nil
        }
        return folder
    }

    /// Each model has its own tokenizer. Checking for "any tokenizer" would let a model
    /// switch load without one, and WhisperKit would then quietly download it.
    private static func hasTokenizer(for model: SpeechModel) -> Bool {
        FileManager.default.fileExists(atPath: baseDirectory.appending(path: model.tokenizerPath).path)
    }
}
