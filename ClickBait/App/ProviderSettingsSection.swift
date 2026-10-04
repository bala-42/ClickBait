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
            // Row builder is nonisolated: see the note in SettingsWindowController.swift.
            ForEach(ProviderKind.allCases, content: Self.providerRow)
        }
        .onChange(of: settings.provider) { testResult = nil }

        switch settings.provider {
        case .ollama:
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

    private nonisolated static func providerRow(_ kind: ProviderKind) -> some View {
        Text(kind.displayName).tag(kind)
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
