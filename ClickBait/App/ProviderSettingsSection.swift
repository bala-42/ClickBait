import ClickBaitCore
import SwiftUI

/// Provider picker, model names, the Anthropic key (Keychain) and a connection test.
struct ProviderSettingsSection: View {
    @Bindable var settings: AppSettings

    @State private var keyDraft = ""
    @State private var hasSavedKey = KeychainStore.read(.anthropicAPIKey) != nil
    @State private var isReplacingKey = false
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
            if !hasSavedKey {
                Label("Save an API key before using Internet Mode.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text("Internet Mode sends screenshots and task context to Anthropic: your question, selected text, text chat history, and any app, window, or readable on-screen details ClickBait collects for the task. Ordinary asks use the model's normal reasoning level. Strawberry-red part tours send the marked close-up and candidate names, use higher reasoning, and may search the web for specialist context to improve visual matching. A tour can use up to three searches if a long request has to resume; Anthropic charges US$0.01 per search plus model token costs, so the tour can take longer and cost more. ClickBait won't automatically switch providers. Your key stays in the macOS Keychain.")
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
        if hasSavedKey && !isReplacingKey {
            HStack {
                Label("API key saved in Keychain", systemImage: "key.fill")
                Spacer()
                Button("Replace") {
                    isReplacingKey = true
                    keyDraft = ""
                    keyError = nil
                    testResult = nil
                }
                Button("Remove") {
                    KeychainStore.delete(.anthropicAPIKey)
                    hasSavedKey = false
                    isReplacingKey = false
                    keyDraft = ""
                    keyError = nil
                    testResult = nil
                }
            }
        } else {
            HStack {
                SecureField(hasSavedKey ? "New API key" : "API key", text: $keyDraft, prompt: Text("sk-ant-…"))
                Button(hasSavedKey ? "Replace" : "Save") { saveKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isReplacingKey {
                    Button("Cancel") {
                        isReplacingKey = false
                        keyDraft = ""
                        keyError = nil
                    }
                }
            }
            if let keyError {
                Text(keyError).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            // KeychainStore updates the existing item in place. A failed replacement
            // leaves the previously saved key intact.
            try KeychainStore.save(key, for: .anthropicAPIKey)
            keyDraft = ""
            keyError = nil
            isReplacingKey = false
            hasSavedKey = true
            testResult = nil
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
