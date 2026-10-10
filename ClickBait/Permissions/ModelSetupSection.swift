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
    private let settings: AppSettings
    private var polling: Task<Void, Never>?

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

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }
}

/// The onboarding's "AI model" section: what to do until Ollama and the model are ready.
struct ModelSetupSection: View {
    let checker: ModelSetupChecker
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI model").font(.headline)
                Spacer()
                status
            }
            switch checker.state {
            case .checking:
                EmptyView()
            case .ready:
                Text("Ollama is running with \(OllamaProvider.defaultModel). Answers stay on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            case .noOllama:
                Text("ClickBait answers with Ollama, which runs AI models on your Mac. Install it, open it, then come back here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Get Ollama…") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
            case .missingModel(let model):
                Text("Ollama is running. Download the model (about 6.6 GB) by running this in Terminal:")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("ollama pull \(model)")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("ollama pull \(model)", forType: .string)
                        copied = true
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch checker.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .noOllama, .missingModel:
            Label("Needed", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
}
