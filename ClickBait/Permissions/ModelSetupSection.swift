import AppKit
import ClickBaitCore
import SwiftUI

/// Whether the AI that answers is ready: Ollama running with the model pulled. Friends
/// installing ClickBait need both before the first question; without this the first
/// question just failed.
@MainActor
@Observable
final class ModelSetupChecker {
    enum State: Equatable {
        case checking
        case ready
        /// Ollama isn't installed or isn't running.
        case noOllama
        /// Ollama runs, but the model isn't pulled.
        case missingModel(String)
    }

    private(set) var state: State = .checking
    /// Downloading the model from setup (`OllamaSetup.pull`): how far, 0…1, while it runs.
    private(set) var downloading = false
    private(set) var downloaded: Double?
    private(set) var downloadProblem: String?
    private let settings: AppSettings
    private var polling: Task<Void, Never>?
    private var download: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isReady: Bool { state == .ready }

    func check() async {
        let provider = settings.makeProvider()
        do {
            try await provider.checkConnection()
            state = .ready
        } catch let error as LLMError {
            switch error {
            case .modelNotFound(let model): state = .missingModel(model)
            default: state = .noOllama
            }
        } catch {
            state = .noOllama
        }
    }

    func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    var model: String { settings.ollamaModel.trimmingCharacters(in: .whitespaces) }

    /// Starts (or resumes) the model download; it carries on while setup moves on or closes.
    func startDownload() {
        guard download == nil else { return }
        downloading = true
        downloadProblem = nil
        let model = model
        download = Task { [weak self] in
            do {
                try await OllamaSetup.pull(model) { [weak self] progress in
                    Task { @MainActor in
                        if let fraction = progress.fraction { self?.downloaded = fraction }
                    }
                }
                await self?.check()
            } catch OllamaSetup.PullError.failed(let reason) {
                self?.downloadProblem = reason
            } catch {
                self?.downloadProblem = "Ollama stopped answering. Open Ollama and try again."
            }
            self?.downloading = false
            self?.download = nil
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }
}
