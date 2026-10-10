import ClickBaitCore
import SwiftUI

/// The local models (Ollama) and a connection test.
struct ProviderSettingsSection: View {
    @Bindable var settings: AppSettings

    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        TextField("Main model", text: $settings.ollamaModel, prompt: Text(OllamaProvider.defaultModel))
            .onChange(of: settings.ollamaModel) { testResult = nil }
        TextField("Quick orders (optional)", text: $settings.ollamaFastModel, prompt: Text("none — the main model"))
            .onChange(of: settings.ollamaFastModel) { testResult = nil }
        Text("""
            Runs on this Mac via Ollama. The main model looks at the screen, points and plans walkthroughs. \
            A second, smaller model can read orders faster, but it stays in memory too: leave it empty \
            unless your Mac has memory to spare. Install the main one with `ollama pull \(OllamaProvider.defaultModel)`.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)

        HStack {
            Button("Test Connection") { test() }
                .disabled(isTesting)
            if isTesting {
                ProgressView().controlSize(.small)
            }
            switch testResult {
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
        }
    }

    private func test() {
        let provider = settings.makeProvider()
        isTesting = true
        testResult = nil
        Task {
            do {
                try await provider.checkConnection()
                testResult = .success("\(provider.displayName) is ready")
            } catch {
                testResult = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }
}
