import ClickBaitCore
import SwiftUI

/// The four brains as cards, with what this Mac has: its memory, what's free now and free
/// disk (user's ask, 2026-11-01: setup should say what the Mac can take). Picking an installed
/// brain switches to it; picking one that isn't downloads it (it carries on if this closes),
/// then switches. Used in Settings → AI model and in setup.
/// The brain being downloaded, shared: setup shows its progress on every step (Taby's "your
/// brain is on its way"), and closing the picker doesn't stop it.
@MainActor @Observable
final class BrainDownload {
    static let shared = BrainDownload()
    private(set) var brain: Brain?
    private(set) var fraction: Double?
    private(set) var problem: String?

    func start(_ brain: Brain, settings: AppSettings, done: @escaping @MainActor () -> Void) {
        guard self.brain == nil else { return }
        self.brain = brain
        fraction = 0
        problem = nil
        Task { @MainActor in
            do {
                try await OllamaSetup.pull(brain.model) { progress in
                    Task { @MainActor in if let f = progress.fraction { BrainDownload.shared.fraction = f } }
                }
                settings.ollamaModel = brain.model
                // The search model comes with every brain (smart search, and meaning matches).
                try? await OllamaSetup.pull(Embedder.model) { _ in }
            } catch {
                problem = "couldn't download \(brain.name): \(error.localizedDescription)"
            }
            self.brain = nil
            done()
        }
    }

    func fail(_ message: String) { problem = message }
}

struct BrainPicker: View {
    @Bindable var settings: AppSettings

    @State private var installed: [String]?
    @State private var download = BrainDownload.shared
    private var downloading: Brain? { download.brain }
    private var fraction: Double? { download.fraction }
    private var problem: String? { download.problem }
    @State private var freeMemory = MachineFacts.freeMemoryGB
    @State private var freeDisk = MachineFacts.freeDiskGB
    private let memory = MachineFacts.memoryGB

    private var chosen: Brain? { Brain.matching(model: settings.ollamaModel) }
    private var recommended: Brain { Brain.recommended(macMemoryGB: memory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                fact("this mac · \(Int(memory.rounded())) GB memory")
                fact("\(String(format: "%.1f", freeMemory)) GB free now", warn: freeMemory < (chosen ?? recommended).memoryGB)
                fact("\(Int(freeDisk)) GB free on disk", warn: freeDisk < 10)
            }
            ForEach(Brain.allCases) { brain in card(brain) }
            if let downloading {
                ProgressView(value: fraction ?? 0)
                Text("downloading \(downloading.name)… \(Int((fraction ?? 0) * 100))%. it carries on if you close this.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if installed == nil {
                Text("ollama isn't running: open it to download or switch brains.").font(.caption).foregroundStyle(.orange)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .task {
            while !Task.isCancelled {
                installed = await OllamaSetup.installedModels()
                freeMemory = MachineFacts.freeMemoryGB
                freeDisk = MachineFacts.freeDiskGB
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func fact(_ text: String, warn: Bool = false) -> some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(warn ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
    }

    private func card(_ brain: Brain) -> some View {
        let isChosen = chosen == brain
        let isInstalled = brain.isInstalled(in: installed ?? [])
        let fit = brain.fitNote(macMemoryGB: memory)
        return Button { pick(brain) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(brain.name).font(.headline)
                    if brain == recommended {
                        Text("recommended").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: Capsule())
                    }
                    Spacer()
                    Image(systemName: "info.circle").foregroundStyle(.secondary).help(brain.modelLabel)
                    if isChosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
                Text(brain.blurb).font(.callout).foregroundStyle(.secondary)
                Text(isInstalled ? "downloaded · needs ~\(Int(brain.memoryGB)) GB memory"
                                 : "\(String(format: "%.1f", brain.downloadGB)) GB download · needs ~\(Int(brain.memoryGB)) GB memory · \(Int(max(0, freeDisk - brain.downloadGB))) GB left after")
                    .font(.caption).foregroundStyle(.secondary)
                if let fit { Text(fit).font(.caption).foregroundStyle(.orange) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isChosen ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isChosen ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloading != nil || installed == nil)
        .accessibilityLabel("\(brain.name), \(brain.modelLabel)\(brain == recommended ? ", recommended" : "")\(isChosen ? ", chosen" : "")")
    }

    private func pick(_ brain: Brain) {
        if brain.isInstalled(in: installed ?? []) {
            settings.ollamaModel = (installed ?? []).first { name in ([brain.model] + brain.aliases).contains(name.lowercased()) } ?? brain.model
            return
        }
        guard freeDisk > brain.downloadGB + 1 else {
            download.fail("not enough disk for \(brain.name): it needs \(String(format: "%.1f", brain.downloadGB)) GB.")
            return
        }
        download.start(brain, settings: settings) { Task { @MainActor in installed = await OllamaSetup.installedModels() } }
    }
}
