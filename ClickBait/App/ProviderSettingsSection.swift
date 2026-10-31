import ClickBaitCore
import SwiftUI

/// The local models (Ollama) and a connection test.
struct ProviderSettingsSection: View {
    @Bindable var settings: AppSettings

    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var geminiKey = ""
    @State private var hasGeminiKey = GeminiKeyStore.read() != nil
    @State private var geminiTestResult: TestResult?
    @State private var isTestingGemini = false

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Text("Google AI Studio key")
            .font(.system(size: 15, weight: .semibold))
        Text("Paste the API key you copied from Google AI Studio. ClickBait saves it in local preferences, not Keychain.")
            .font(.callout)
            .foregroundStyle(.secondary)
        SecureField(hasGeminiKey ? "Gemini API key saved on this Mac" : "Paste Google AI Studio API key", text: $geminiKey)
            .textFieldStyle(.roundedBorder)
            .textContentType(.password)
            .privacySensitive()
        HStack {
            Button("Save Key") {
                GeminiKeyStore.save(geminiKey)
                geminiKey = ""
                hasGeminiKey = GeminiKeyStore.read() != nil
                geminiTestResult = nil
            }
            .disabled(geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasGeminiKey {
                Button("Remove Key", role: .destructive) {
                    GeminiKeyStore.delete()
                    hasGeminiKey = false
                    settings.geminiInternetAnswers = false
                    geminiTestResult = nil
                }
            }
            Button("Test Gemini") { testGemini() }
                .disabled(!hasGeminiKey || isTestingGemini)
            if isTestingGemini { ProgressView().controlSize(.small) }
        }
        Toggle("Use Gemini for Internet Mode answers", isOn: $settings.geminiInternetAnswers)
            .disabled(!hasGeminiKey)
        Text("Gemini runs only when Internet Mode is on and a lookup returns results. Google receives the cleaned search phrase and retrieved excerpts; screenshots, raw screen text, and chat history stay on this Mac. Google may use free-tier prompts to improve its products. Uses Gemini 3.8 Flash without Search grounding. To keep usage on the free tier, use a Google project with billing off; ClickBait cannot inspect or change Google billing.")
            .font(.callout)
            .foregroundStyle(.secondary)
        switch geminiTestResult {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case nil:
            EmptyView()
        }

        Divider().padding(.vertical, 4)
        Text("Local model (Ollama)")
            .font(.system(size: 15, weight: .semibold))
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

    private func testGemini() {
        guard let key = GeminiKeyStore.read() else { return }
        isTestingGemini = true
        geminiTestResult = nil
        Task {
            do {
                try await GeminiInternetProvider(apiKey: key).checkConnection()
                geminiTestResult = .success("Gemini is reachable")
            } catch {
                geminiTestResult = .failure(error.localizedDescription)
            }
            isTestingGemini = false
        }
    }
}
