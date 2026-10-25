import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Model picker + download and import buttons, shared by Settings and the onboarding window.
struct SpeechModelSection: View {
    @Bindable var settings: AppSettings
    let speech: SpeechModelManager
    var showsPicker = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsPicker {
                Picker("Model", selection: $settings.speechModel) {
                    // Row builder is nonisolated: see the note in SettingsWindowController.swift.
                    ForEach(SpeechModel.offered, content: Self.modelRow)
                }
                .onChange(of: settings.speechModel) { speech.loadIfInstalled() }
                .disabled(isBusy)
            }

            HStack(spacing: 8) {
                status
                Spacer()
                if needsDownload {
                    if settings.speechModel != .apple { Button("Import from a file…") { chooseFile() } }
                    Button("Download") { speech.download() }
                }
            }

            Text(settings.speechModel == .apple
                 ? "Speech is recognized on your Mac by Apple's on-device model. macOS downloads it once from Apple when you click Download; your speech never leaves your Mac."
                 : "Speech is recognized on your Mac. The model is downloaded once from Hugging Face when you click Download — nothing else ever leaves your Mac for this. No internet? Import the SpeechModels folder (or a .zip of it) from a Mac that has it: ~/Library/Application Support/ClickBait/SpeechModels.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Your filler words", text: $settings.fillerWords, prompt: Text("e.g. kind of, you see"))
            Text("Dictation already drops \"um\", \"erm\" and openers like \"yeah, so, hi, just\". Add your own here, separated by commas.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private nonisolated static func modelRow(_ model: SpeechModel) -> some View {
        Text(model.displayName).tag(model)
    }

    @ViewBuilder private var status: some View {
        switch speech.state {
        case .notDownloaded:
            Label("Not downloaded", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading… \(Int(fraction * 100))%")
            }
            .frame(maxWidth: 260)
        case .importing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Importing…")
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…")
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isBusy: Bool {
        switch speech.state {
        case .downloading, .importing: true
        default: false
        }
    }

    /// A folder or .zip; checked and copied by `SpeechModelManager.importModel`, offline.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Import a Speech Model"
        panel.message = "Choose the SpeechModels folder, or a .zip of it, from a Mac where ClickBait has the model (~/Library/Application Support/ClickBait/SpeechModels)."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        speech.importModel(from: url)
    }

    private var needsDownload: Bool {
        switch speech.state {
        case .notDownloaded, .failed: true
        default: false
        }
    }
}
