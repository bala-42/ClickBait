import ClickBaitCore
import SwiftUI

/// Provider picker, model names, the Anthropic key (Keychain) and a connection test.
struct ProviderSettingsSection: View {
    @Bindable var settings: AppSettings

    @State private var keyDraft = ""
    @State private var hasSavedKey = KeychainStore.read(.anthropicAPIKey) != nil
    @State private var keyError: String?
    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Picker("Answer with", selection: $settings.provider) {
            ForEach(ProviderKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .onChange(of: settings.provider) { testResult = nil }

        switch settings.provider {
        case .ollama:
            TextField("Ollama model", text: $settings.ollamaModel, prompt: Text(OllamaProvider.defaultModel))
                .onChange(of: settings.ollamaModel) { testResult = nil }
            Text("Runs on this Mac via Ollama. Install a vision model with `ollama pull \(OllamaProvider.defaultModel)`.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .anthropic:
            TextField("Anthropic model", text: $settings.anthropicModel, prompt: Text(AnthropicProvider.defaultModel))
                .onChange(of: settings.anthropicModel) { testResult = nil }
            apiKeyRow
            Text("Your screenshot and question are sent to Anthropic with your key. The key is stored in your Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

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

    @ViewBuilder private var apiKeyRow: some View {
        if hasSavedKey {
            HStack {
                Label("API key saved in Keychain", systemImage: "key.fill")
                Spacer()
                Button("Remove") {
                    KeychainStore.delete(.anthropicAPIKey)
                    hasSavedKey = false
                    testResult = nil
                }
            }
        } else {
            HStack {
                SecureField("API key", text: $keyDraft, prompt: Text("sk-ant-…"))
                Button("Save") { saveKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let keyError {
                Text(keyError).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private func saveKey() {
        do {
            try KeychainStore.save(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines), for: .anthropicAPIKey)
            keyDraft = ""
            keyError = nil
            hasSavedKey = true
        } catch {
            keyError = error.localizedDescription
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
