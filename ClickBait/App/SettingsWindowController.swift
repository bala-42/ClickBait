import AppKit
import ClickBaitCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let speech: SpeechModelManager
    let speaker: Speaker
    let searxng: SearXNGStatus
    let returnLabel: String
    let onBack: () -> Void
    let onCollapse: () -> Void

    @State private var selectedPage: SettingsPage = .general

    private let aqua = Color(red: 0.43, green: 0.73, blue: 1.0)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 225)
            Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(selectedPage.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(action: onCollapse) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close settings and collapse notch")
                }
                Text(selectedPage.subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.top, 4)
                    pageForm
                        .padding(.top, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 27)
                .padding(.top, 28)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.075, green: 0.08, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
        .tint(aqua)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 17) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(returnLabel)

            Text("Settings")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(.white)
                .padding(.leading, 8)

            VStack(spacing: 5) {
                ForEach(SettingsPage.allCases) { page in
                    Button { selectedPage = page } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 20)
                            Text(page.title).font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selectedPage == page ? .white : .white.opacity(0.58))
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(selectedPage == page ? Color.white.opacity(0.13) : .clear,
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
            Text("ClickBait")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.leading, 9)
        }
        .padding(.horizontal, 15)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .background(Color.white.opacity(0.035))
    }

    @ViewBuilder
    private var pageForm: some View {
        switch selectedPage {
        case .general:
            Form {
                Section("Hotkey") {
                    Text("Hold Control+Option, ask your question out loud, then let go.")
                    Text("Pressing any other key while holding cancels, so shortcuts like ⌃⌥← still work.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Behavior") {
                    Toggle("Carry out spoken commands", isOn: $settings.commandsEnabled)
                        .toggleStyle(AquaToggleStyle())
                    Toggle("Morning suggestions", isOn: $settings.morningCards)
                        .toggleStyle(AquaToggleStyle())
                        .onChange(of: settings.morningCards) { _, on in if on { MorningBrief.requestAccess() } }
                    Text("Once a day, after 5 am, the local model reads today's reminders and events and what you asked it to remember, and offers up to three things to ask, as a card in the dock. Nothing runs until you tap one; nothing leaves your Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Notch") {
                    Toggle("Show volume controls when using volume keys", isOn: $settings.notchVolumeHUD)
                        .toggleStyle(AquaToggleStyle())
                    Toggle("Show Spotify artwork in the notch", isOn: $settings.spotifyArtworkAlways)
                        .toggleStyle(AquaToggleStyle())
                }
            }.settingsPanelStyle()
        case .commands:
            Form {
                Section {
                    CommandsSettingsSection(settings: settings)
                } footer: {
                    Text("Say an order like “open Safari”, “volume 30”, “dark mode” or “run Focus Time” while holding ⌃⌥. Questions still just get an answer. Only the shortcuts you tick can be run, and those run without asking.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.settingsPanelStyle()
        case .voice:
            Form { Section("Voice") { VoiceSettingsSection(settings: settings, speaker: speaker) } }.settingsPanelStyle()
        case .speech:
            Form { Section("Speech recognition") { SpeechModelSection(settings: settings, speech: speech) } }.settingsPanelStyle()
        case .aiModel:
            Form { Section("AI model") { ProviderSettingsSection(settings: settings) } }.settingsPanelStyle()
        case .internet:
            Form { Section("Internet") { InternetSettingsSection(searxng: searxng) } }.settingsPanelStyle()
        case .privacy:
            Form {
                Section {
                    BlocklistEditor(blocklist: $settings.blocklist)
                } header: {
                    Text("Never look at these apps")
                } footer: {
                    Text("While one of these is the frontmost app, ClickBait won't take a screenshot.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Screen capture") {
                    Toggle("Ignore ClickBait in captures", isOn: $settings.ignoreNotchInCaptures)
                        .toggleStyle(AquaToggleStyle())
                    Text("Keeps the notch panel and other ClickBait windows out of screenshots ClickBait takes. This does not change macOS screenshots or recordings made by other apps.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Uninstall") {
                    Button("Uninstall ClickBait…", role: .destructive) { Uninstaller.confirmAndRun() }
                    Text("Deletes ClickBait's files, speech model and settings, resets its permissions, then quits. Ollama and its models stay.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.settingsPanelStyle()
        case .debugging:
            Form {
                Section("Debugging") {
                    Toggle("Keep the last screenshot and recording", isOn: $settings.keepDebugCaptures)
                        .toggleStyle(AquaToggleStyle())
                        .onChange(of: settings.keepDebugCaptures) { _, keep in
                            if !keep { DebugCaptureStore.deleteAll() }
                        }
                    Text("Saved to a temporary folder (menu bar → Reveal Last Capture) and deleted when you turn this off.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.settingsPanelStyle()
        }
    }
}

private extension Form {
    func settingsPanelStyle() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .toggleStyle(AquaToggleStyle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AquaToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn
                              ? LinearGradient(colors: [Color(red: 0.82, green: 0.94, blue: 1),
                                                        Color(red: 0.36, green: 0.68, blue: 0.96)],
                                               startPoint: .top, endPoint: .bottom)
                              : LinearGradient(colors: [Color(white: 0.32), Color(white: 0.20)],
                                               startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(LinearGradient(colors: [.white.opacity(configuration.isOn ? 0.8 : 0.18), .clear],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(height: 12)
                                .padding(.horizontal, 2)
                                .padding(.top, 2)
                        }
                        .overlay {
                            Capsule().strokeBorder(configuration.isOn ? Color(red: 0.48, green: 0.69, blue: 1)
                                : Color.white.opacity(0.13), lineWidth: 1)
                        }
                        .frame(width: 46, height: 26)
                    Circle()
                        .fill(Color.black)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.72), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .frame(width: 20, height: 20)
                        .padding(3)
                }
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, commands, voice, speech, aiModel, internet, privacy, debugging

    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .commands: "Commands"
        case .voice: "Voice"
        case .speech: "Speech recognition"
        case .aiModel: "AI model"
        case .internet: "Internet"
        case .privacy: "Privacy"
        case .debugging: "Debugging"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .commands: "command"
        case .voice: "waveform"
        case .speech: "mic.fill"
        case .aiModel: "cpu"
        case .internet: "globe"
        case .privacy: "hand.raised.fill"
        case .debugging: "ladybug.fill"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "How ClickBait behaves on your Mac."
        case .commands: "Choose which spoken shortcuts ClickBait can run."
        case .voice: "Choose how ClickBait reads answers aloud."
        case .speech: "Set up on-device speech recognition."
        case .aiModel: "Configure the local model used for questions and actions."
        case .internet: "Optional search sources for Internet Mode."
        case .privacy: "Control which apps ClickBait may inspect."
        case .debugging: "Manage temporary diagnostic captures."
        }
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
            .toggleStyle(AquaToggleStyle())

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
                .toggleStyle(AquaToggleStyle())
                .disabled(!settings.commandsEnabled)
        }
        // Shortcuts that were allowed but no longer exist stay visible so they can be removed.
        ForEach(settings.allowedShortcuts.filter { !shortcuts.contains($0) && !isLoading }, id: \.self) { name in
            Toggle("\(name) (not found)", isOn: allowed(name))
                .toggleStyle(AquaToggleStyle())
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
