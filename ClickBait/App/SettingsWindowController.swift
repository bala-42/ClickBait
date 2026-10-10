import AppKit
import ClickBaitCore
import SwiftUI

/// Hosts the SwiftUI settings view in a regular window. A menu bar app has no main
/// window, so it activates itself before showing this one.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: AppSettings, speech: SpeechModelManager, speaker: Speaker) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClickBait Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings, speech: speech, speaker: speaker))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let speech: SpeechModelManager
    let speaker: Speaker

    var body: some View {
        Form {
            Section("Hotkey") {
                Text("Hold Control+Option, ask your question out loud, then let go.")
                Text("Pressing any other key while holding cancels, so shortcuts like ⌃⌥← still work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                CommandsSettingsSection(settings: settings)
            } header: {
                Text("Commands")
            } footer: {
                Text("Say an order like “open Safari”, “volume 30”, “dark mode” or “run Focus Time” while holding ⌃⌥. Questions still just get an answer. Only the shortcuts you tick can be run, and those run without asking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Voice") {
                VoiceSettingsSection(settings: settings, speaker: speaker)
            }

            Section("Speech recognition") {
                SpeechModelSection(settings: settings, speech: speech)
            }

            Section("AI model") {
                ProviderSettingsSection(settings: settings)
            }

            Section {
                BlocklistEditor(blocklist: $settings.blocklist)
            } header: {
                Text("Never look at these apps")
            } footer: {
                Text("While one of these is the frontmost app, ClickBait won't take a screenshot.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Debugging") {
                Toggle("Keep the last screenshot and recording", isOn: $settings.keepDebugCaptures)
                    .onChange(of: settings.keepDebugCaptures) { _, keep in
                        if !keep { DebugCaptureStore.deleteAll() }
                    }
                Text("Saved to a temporary folder (menu bar → Reveal Last Capture) and deleted when you turn this off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, minHeight: 640)
    }
}

// SwiftUI on macOS 27 can build picker/menu rows on a background thread. A row
// closure written inside a view body is main-actor isolated, and Swift 6 traps when
// it runs elsewhere (this crashed the Voice picker). So list rows are built by
// `nonisolated` functions, passed by reference.

private struct BlocklistEditor: View {
    @Binding var blocklist: AppBlocklist
    @State private var appToAdd: String?

    var body: some View {
        ForEach(blocklist.apps) { app in
            HStack {
                VStack(alignment: .leading) {
                    Text(app.name)
                    Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    blocklist.remove(bundleID: app.bundleID)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(app.name)")
            }
        }

        HStack {
            Picker("Add Running App", selection: $appToAdd) {
                Text("Add Running App…").tag(String?.none)
                ForEach(addableApps, id: \.bundleID, content: Self.appRow)
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: appToAdd) { _, bundleID in
                guard let bundleID, let app = addableApps.first(where: { $0.bundleID == bundleID }) else { return }
                blocklist.add(app)
                appToAdd = nil
            }
            Spacer()
            Button("Restore Defaults") { blocklist = .defaults }
        }
    }

    private nonisolated static func appRow(_ app: BlockedApp) -> some View {
        Text(app.name).tag(Optional(app.bundleID))
    }

    private var addableApps: [BlockedApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> BlockedApp? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
                return BlockedApp(bundleID: id, name: app.localizedName ?? id)
            }
            .filter { !blocklist.isBlocked(bundleID: $0.bundleID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct VoiceOption: Identifiable, Sendable {
    let id: String
    let title: String
}

private struct VoiceSettingsSection: View {
    @Bindable var settings: AppSettings
    let speaker: Speaker

    private let voices = Speaker.availableVoices.map {
        VoiceOption(id: $0.identifier, title: "\($0.name) — \($0.language), \($0.quality.label)")
    }

    private nonisolated static func voiceRow(_ voice: VoiceOption) -> some View {
        Text(voice.title).tag(Optional(voice.id))
    }

    var body: some View {
        Toggle("Read answers aloud", isOn: $settings.speakAnswers)
        Picker("Voice", selection: $settings.voiceIdentifier) {
            Text("Automatic (best for your language)").tag(String?.none)
            ForEach(voices, content: Self.voiceRow)
        }
        .disabled(!settings.speakAnswers)
        HStack {
            Text("Speed")
            Slider(value: $settings.speechRate, in: 0.4...0.62)
            Button("Preview") { speaker.preview() }
        }
        .disabled(!settings.speakAnswers)
        Text("Uses the voices built into macOS, on your Mac. For nicer voices, download “Enhanced” or “Premium” ones in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CommandsSettingsSection: View {
    @Bindable var settings: AppSettings
    @State private var shortcuts: [String] = []
    @State private var isLoading = false

    var body: some View {
        Toggle("Carry out spoken commands", isOn: $settings.commandsEnabled)

        HStack {
            Text("Shortcuts ClickBait may run").font(.headline)
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Button("Refresh") { load() }
        }
        .disabled(!settings.commandsEnabled)

        if shortcuts.isEmpty, !isLoading {
            Text("No shortcuts found. Make some in the Shortcuts app, then click Refresh.")
                .foregroundStyle(.secondary)
        }
        ForEach(shortcuts, id: \.self) { name in
            Toggle(name, isOn: allowed(name))
                .disabled(!settings.commandsEnabled)
        }
        // Shortcuts that were allowed but no longer exist stay visible so they can be removed.
        ForEach(settings.allowedShortcuts.filter { !shortcuts.contains($0) && !isLoading }, id: \.self) { name in
            Toggle("\(name) (not found)", isOn: allowed(name))
        }
        .onAppear { if shortcuts.isEmpty { load() } }
    }

    private func allowed(_ name: String) -> Binding<Bool> {
        Binding(
            get: { settings.allowedShortcuts.contains(name) },
            set: { isOn in
                settings.allowedShortcuts.removeAll { $0 == name }
                if isOn { settings.allowedShortcuts.append(name) }
            }
        )
    }

    private func load() {
        isLoading = true
        Task {
            shortcuts = await ShortcutsCLI.list()
            isLoading = false
        }
    }
}
