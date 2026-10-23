import AppKit
import ClickBaitCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let speech: SpeechModelManager
    let speaker: Speaker
    let searxng: SearXNGStatus
    /// The menu bar's menu: Settings offers every item it has.
    var menu: StatusBarController?
    var health: HealthLadder.Item?
    var permissions: PermissionsManager?
    /// The page to show first (the notch's shortcuts card opens Shortcuts).
    var startPage: SettingsPage = .general
    let returnLabel: String
    let onBack: () -> Void
    let onCollapse: () -> Void

    @State private var selectedPage: SettingsPage = .general
    @State private var microphones: [Microphones.Device] = []
    @State private var micTest = MicrophoneTest()
    /// Chrome's "Allow JavaScript from Apple Events": on, off, or unknown (Chrome isn't open).
    @State private var chromeScripting: Bool?
    @State private var checkingChrome = false
    @State private var savedCovers = 0

    private let aqua = AquaDark.link

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 225)
            Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(selectedPage.title)
                        .font(.system(size: 20, weight: .semibold))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
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
        // The notch's card, as Home and the chat wear it.
        .notchCard()
        .clipShape(RoundedRectangle(cornerRadius: Look.Corner.card, style: .continuous))
        .preferredColorScheme(.dark)
        .tint(aqua)
        .onAppear { selectedPage = startPage }
        .onChange(of: selectedPage) { _, page in
            if page != .microphone { micTest.stop() }
            if page == .permissions { permissions?.refresh() }
        }
        .onDisappear { micTest.stop() }
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
            .overlay(alignment: .leading) {
                // As HeyClicky's: the title beside the way back.
                Text("Settings")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(x: 92)
            }

            ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(SettingsPage.allCases) { page in
                    if let group = page.groupStart {
                        Text(group)
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.38))
                            .padding(.leading, 12)
                            .padding(.top, page == SettingsPage.allCases.first ? 0 : 10)
                    }
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
                        .frame(height: 34)
                        .background(selectedPage == page ? Color.white.opacity(0.13) : .clear,
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            }

            Spacer(minLength: 0)
            Text("ClickBait \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
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
                SettingsSection("Status") {
                    HStack(spacing: 8) {
                        Circle().fill(health?.color ?? .gray).frame(width: 8, height: 8)
                        Text(health?.words ?? "Checking…")
                        Spacer()
                        if case .permissionOff = health { Button("Fix…") { menu?.openPermissions() } }
                    }
                }
                SettingsSection("Hotkey") {
                    Text("Hold Control+Option, ask your question out loud, then let go.")
                    Text("Tap ⌥⌘ to explain highlighted text; double-tap ⌥⌘ to type a question.")
                    Text("Pressing any other key while holding cancels, so shortcuts like ⌃⌥← still work.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                SettingsSection("Behavior") {
                    Toggle(isOn: $settings.commandsEnabled) {
                        RowLabel("Carry out spoken commands", "Say “open Safari”, “volume 30” or “dark mode” while holding ⌃⌥.")
                    }
                    Toggle(isOn: $settings.morningCards) {
                        RowLabel("Morning suggestions", "Once a day after 5 am: up to three things to ask, from today's reminders and events. Nothing leaves your Mac.")
                    }
                    .onChange(of: settings.morningCards) { _, on in if on { MorningBrief.requestAccess() } }
                }
                SettingsSection("Notch") {
                    Toggle(isOn: Binding(get: { settings.notchPanelEnabled }, set: { on in menu?.setNotch(on) })) {
                        RowLabel("Notch panel", "Music, shelf, mirror and chat at the notch. Rest the pointer there to open it.")
                    }
                    Toggle(isOn: $settings.notchVolumeHUD) {
                        RowLabel("Volume in the notch", "The volume keys show their level in the notch instead of macOS's.")
                    }
                    Toggle(isOn: $settings.spotifyArtworkAlways) {
                        RowLabel("Spotify covers always", "Downloads album art even with Internet Mode off.")
                    }
                }
                SettingsSection("Sounds and greetings") {
                    Toggle(isOn: $settings.soundCues) {
                        RowLabel("Sounds", "A soft sound when a background ClickBait is done, and when ClickBait needs your yes.")
                    }
                    Toggle(isOn: $settings.greetings) {
                        RowLabel("Greetings", "A hello by the cursor on the first wake of the day, or after a long time away.")
                    }
                }
                SettingsSection("Background ClickBaits") {
                    let jobs = menu?.backgroundJobs ?? []
                    if jobs.isEmpty {
                        Text("No background tasks").foregroundStyle(.secondary)
                    }
                    ForEach(jobs) { entry in
                        Button { menu?.showCapsule(entry.id) } label: {
                            HStack {
                                Text(entry.job.question).lineLimit(1)
                                Spacer()
                                Text(Self.status(entry.job.status)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                SettingsSection("Your things") {
                    Button("Remembered…") { MemoryStore.shared.reveal() }
                    Button("Notes Folder…") { MemoryStore.shared.revealNotes() }
                    Button("Saved Answers…") { AnswerArchive.reveal() }
                }
                SettingsSection("ClickBait") {
                    Button("Permissions…") { menu?.openPermissions() }
                    Button("About ClickBait") { menu?.openAbout() }
                    Button("Quit ClickBait", role: .destructive) { menu?.quit() }
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
            Form { SettingsSection("Voice") { VoiceSettingsSection(settings: settings, speaker: speaker) } }.settingsPanelStyle()
        case .speech:
            Form { SettingsSection("Speech recognition") { SpeechModelSection(settings: settings, speech: speech) } }.settingsPanelStyle()
        case .aiModel:
            Form { SettingsSection("AI model") { ProviderSettingsSection(settings: settings) } }.settingsPanelStyle()
        case .internet:
            Form {
                Section {
                    Toggle(isOn: Binding(get: { settings.internet.isOn },
                                         set: { if $0 != settings.internet.isOn { settings.internet.toggle() } })) {
                        RowLabel(settings.internet.isOn ? "Internet Mode: on 🌐" : "Internet Mode: off 🔒",
                                 "Free lookups when you ask; only search words leave your Mac. Off every time ClickBait starts.")
                    }
                }
                SettingsSection("Recent searches") {
                    if settings.internet.recent.isEmpty {
                        Text("Nothing looked up yet").foregroundStyle(.secondary)
                    }
                    ForEach(settings.internet.recent, id: \.self) { Text($0).lineLimit(1) }
                }
                SettingsSection("Internet") { InternetSettingsSection(searxng: searxng) }
            }.settingsPanelStyle()
        case .privacy:
            Form {
                Section {
                    BlocklistEditor(blocklist: $settings.blocklist)
                } header: {
                    SettingsHeader("Never look at these apps")
                } footer: {
                    Text("While one of these is the frontmost app, ClickBait won't take a screenshot.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                SettingsSection("Screen capture") {
                    Toggle(isOn: $settings.ignoreNotchInCaptures) {
                        RowLabel("Ignore ClickBait in captures", "Keeps ClickBait's own windows out of the screenshots it takes. Other apps' recordings are unchanged.")
                    }
                }
                SettingsSection("Saved covers") {
                    HStack {
                        RowLabel("\(savedCovers) cover\(savedCovers == 1 ? "" : "s") saved on this Mac",
                                 "Spotify covers and YouTube thumbnails downloaded with Internet Mode on, kept so the notch shows them with it off.")
                        Spacer(minLength: 12)
                        Button("Clear") { CoverCache.clear(); savedCovers = 0 }
                            .disabled(savedCovers == 0)
                    }
                    .onAppear { savedCovers = CoverCache.count }
                }
                SettingsSection("Uninstall") {
                    Button("Uninstall ClickBait…", role: .destructive) { Uninstaller.confirmAndRun() }
                    Text("Deletes ClickBait's files, speech model and settings, resets its permissions, then quits. Ollama and its models stay.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.settingsPanelStyle()
        case .shortcuts:
            Form {
                SettingsSection("Talk to ClickBait") {
                    ForEach(ShortcutList.items) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShortcutKeys(item: item)
                        }
                    }
                }
                Section {
                    Text("These keys are fixed for now; changing them is coming.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.settingsPanelStyle()
        case .microphone:
            Form {
                SettingsSection("Input device") {
                    Picker("Microphone", selection: $settings.microphoneUID) {
                        Text("System Default").tag(String?.none)
                        ForEach(microphones, content: Self.microphoneRow)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: settings.microphoneUID) { _, _ in if micTest.isRunning { micTest.start() } }
                }
                SettingsSection("Test") {
                    HStack(spacing: 14) {
                        Button(micTest.isRunning ? "Stop" : "Test microphone") {
                            if micTest.isRunning { micTest.stop() } else { micTest.start() }
                        }
                        LevelBars(level: micTest.level)
                        Spacer()
                    }
                    Text(micTest.failure ?? "Speak normally: the bars should move as ClickBait hears you. Nothing is kept.")
                        .font(.callout).foregroundStyle(micTest.failure == nil ? .secondary : CompanionTone.problem)
                }
            }
            .settingsPanelStyle()
            .onAppear { microphones = Microphones.all() }
        case .permissions:
            Form {
                Section {
                    ForEach(PermissionKind.allCases) { kind in
                        let status = permissions?.status(of: kind) ?? .notDetermined
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbolName).frame(width: 22).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                Text(kind.reason).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            if status == .granted {
                                Label("Allowed", systemImage: "checkmark.circle.fill")
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(AquaDark.aquaGreen)
                                    .font(.system(size: 12, weight: .semibold))
                            } else {
                                Button(status == .denied ? "Open Settings" : "Allow") { permissions?.request(kind) }
                            }
                        }
                    }
                } footer: {
                    Text("ClickBait asks only for what it uses. Everything it sees and hears stays on your Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                SettingsSection("Browser") {
                    HStack(spacing: 12) {
                        Image(systemName: "play.rectangle.fill").frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("YouTube controls in Chrome")
                            Text("Lets the notch play, pause, skip and show the time of a YouTube video in its own tab. Turn it on in Chrome's menu bar: View → Developer → Allow JavaScript from Apple Events.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        switch chromeScripting {
                        case true?:
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(AquaDark.aquaGreen)
                                .font(.system(size: 12, weight: .semibold))
                        default:
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(chromeScripting == false ? "Off" : "Open Chrome to check")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Button(checkingChrome ? "Checking…" : "Check again") { Task { await checkChrome() } }
                                    .disabled(checkingChrome)
                            }
                        }
                    }
                }
            }
            .settingsPanelStyle()
            .task { await checkChrome() }
            .task {
                // Picks up a switch flipped in System Settings while this page is open.
                while !Task.isCancelled {
                    permissions?.refresh()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        case .debugging:
            Form {
                SettingsSection("Debugging") {
                    Toggle(isOn: $settings.keepDebugCaptures) {
                        RowLabel("Keep the last screenshot and recording", "Saved to a temporary folder and deleted when you turn this off.")
                    }
                    .onChange(of: settings.keepDebugCaptures) { _, keep in
                        if !keep { DebugCaptureStore.deleteAll() }
                    }
                    if settings.keepDebugCaptures {
                        Button("Reveal Last Capture") { menu?.revealLastCapture() }
                    }
                    #if DEBUG
                    Button("Test Capsule (Local)") { menu?.runDebugCapsuleTest() }
                    #endif
                }
            }.settingsPanelStyle()
        }
    }
}

extension SettingsView {
    /// Runs a harmless `1` in Chrome's front tab (only if Chrome is open): refused means the
    /// switch is off.
    private func checkChrome() async {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty else {
            chromeScripting = nil
            return
        }
        checkingChrome = true
        defer { checkingChrome = false }
        do {
            try await AppleScriptRunner.run(YouTubeControl.chromeProbe, app: "Google Chrome")
            chromeScripting = true
        } catch {
            chromeScripting = YouTubeControl.isTurnedOff(error.localizedDescription) ? false : nil
        }
    }

    private nonisolated static func microphoneRow(_ device: Microphones.Device) -> some View {
        Text(device.name).tag(Optional(device.id))
    }

    static func status(_ status: BackgroundJob.Status) -> String {
        switch status {
        case .working: "Working"
        case .done: "Ready"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

/// A HeyClicky-style group: its name small, uppercase and grey above a rounded card of rows.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section { content } header: { SettingsHeader(title) }
    }
}

struct SettingsHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.4))
    }
}

/// A setting's row: its name, and what it does in one grey line under it.
struct RowLabel: View {
    let title: String
    let detail: String
    init(_ title: String, _ detail: String) { (self.title, self.detail) = (title, detail) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
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

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, shortcuts, commands, voice, microphone, speech, aiModel, internet, permissions, privacy, debugging

    /// The sidebar's group label shown above this page, if it starts one.
    var groupStart: String? {
        switch self {
        case .general: "CLICKBAIT"
        case .voice: "LISTENING AND SPEAKING"
        case .aiModel: "SETUP"
        default: nil
        }
    }

    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .microphone: "Microphone"
        case .permissions: "Permissions"
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
        case .shortcuts: "keyboard"
        case .microphone: "mic.fill"
        case .permissions: "lock.shield.fill"
        case .commands: "command"
        case .voice: "waveform"
        case .speech: "waveform.badge.mic"
        case .aiModel: "cpu"
        case .internet: "globe"
        case .privacy: "hand.raised.fill"
        case .debugging: "ladybug.fill"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "How ClickBait behaves on your Mac."
        case .shortcuts: "The keys that summon ClickBait."
        case .microphone: "Which microphone ClickBait listens through."
        case .permissions: "What ClickBait may see, hear and do on your Mac."
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

/// ClickBait's keys, for Settings' Shortcuts page and the notch's shortcuts card
/// (`HotkeyMonitor`, `InputInterceptor` own them).
enum ShortcutList {
    struct Item: Identifiable {
        let title: String
        let detail: String
        /// "Hold", "Tap", "Double-tap".
        let how: String
        /// Each key: its symbol and name.
        let keys: [(symbol: String, name: String)]
        var id: String { title }
        /// One word, for the notch's small card.
        var short: String { title == "Push to talk" ? "Talk" : title == "Text mode" ? "Text" : title }
    }

    static let items: [Item] = [
        Item(title: "Push to talk", detail: "Hold, ask out loud, let go.", how: "Hold", keys: [("⌃", "control"), ("⌥", "option")]),
        Item(title: "Explain", detail: "Explains the highlighted text.", how: "Tap", keys: [("⌥", "option"), ("⌘", "command")]),
        Item(title: "Text mode", detail: "Type to ClickBait instead of talking.", how: "Double-tap", keys: [("⌥", "option"), ("⌘", "command")]),
        Item(title: "Snip", detail: "Hold and circle something to ask about it.", how: "Hold", keys: [("⌥", "option"), ("⌘", "command")]),
        Item(title: "Dictate", detail: "Hold and speak; the words go where you type.", how: "Hold", keys: [("fn", ""), ("⌃", "control")]),
        Item(title: "Stop", detail: "Stops what ClickBait is doing.", how: "Press", keys: [("esc", "")]),
    ]
}

/// "Hold [⌃ control] [⌥ option]" as keycaps.
struct ShortcutKeys: View {
    let item: ShortcutList.Item
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Text(item.how).font(.system(size: compact ? 9.5 : 12)).foregroundStyle(.white.opacity(0.5))
            ForEach(Array(item.keys.enumerated()), id: \.offset) { _, key in
                HStack(spacing: 3) {
                    Text(key.symbol).font(.system(size: compact ? 9 : 11, weight: .semibold))
                    if !key.name.isEmpty { Text(key.name).font(.system(size: compact ? 9 : 11, weight: .medium)) }
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, compact ? 4 : 6)
                .frame(height: compact ? 15 : 20)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.how) \(item.keys.map { $0.name.isEmpty ? $0.symbol : $0.name }.joined(separator: " "))")
    }
}

/// The microphone test's meter: a row of bars lit up to the level.
private struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<16, id: \.self) { index in
                Capsule()
                    .fill(Float(index) / 16 < level ? AquaDark.link : Color.white.opacity(0.14))
                    .frame(width: 4, height: 14)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level \(Int(level * 100)) percent")
    }
}
