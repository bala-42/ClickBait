import SwiftUI

/// Model picker + download button, shared by Settings and the onboarding window.
struct SpeechModelSection: View {
    @Bindable var settings: AppSettings
    let speech: SpeechModelManager
    var showsPicker = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsPicker {
                Picker("Model", selection: $settings.speechModel) {
                    // Row builder is nonisolated: see the note in SettingsWindowController.swift.
                    ForEach(SpeechModel.allCases, content: Self.modelRow)
                }
                .onChange(of: settings.speechModel) { speech.loadIfInstalled() }
                .disabled(isDownloading)
            }

            HStack(spacing: 8) {
                status
                Spacer()
                if needsDownload {
                    Button("Download") { speech.download() }
                }
            }

            Text("Speech is recognized on your Mac. The model is downloaded once from Hugging Face when you click Download — nothing else ever leaves your Mac for this.")
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

    private var isDownloading: Bool {
        if case .downloading = speech.state { return true }
        return false
    }

    private var needsDownload: Bool {
        switch speech.state {
        case .notDownloaded, .failed: true
        default: false
        }
    }
}
