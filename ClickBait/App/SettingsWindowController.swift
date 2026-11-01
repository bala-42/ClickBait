import Photos
import AppKit
import ClickBaitCore
import SwiftUI

/// Settings inside the notch, in HeyClicky's character (user's references, 2026-10-23): a
/// sidebar of small rows in named groups, and pages of rounded cards whose rows each carry a
/// name, one grey line of what it does, and a switch, a white pill button or a › on the right.
/// Only what a user acts on: no status lines, duplicated hotkey text or debug tools.
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
    @State private var savedCovers = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Rectangle().fill(SettingsLook.hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedPage.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                        Text(selectedPage.subtitle).font(.system(size: 13)).foregroundStyle(SettingsLook.secondary)
                    }
                    Spacer()
                    Button(action: onCollapse) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(SettingsLook.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close settings and collapse notch")
                }
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) { page }
                        .padding(.horizontal, 30)
                        .padding(.bottom, 26)
                }
                .scrollIndicators(.never)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsLook.page)
        .clipShape(RoundedRectangle(cornerRadius: Look.Corner.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Look.Corner.card, style: .continuous).stroke(SettingsLook.hairline, lineWidth: 1))
        .preferredColorScheme(.dark)
        .tint(SettingsLook.accent)
        .toggleStyle(AquaToggleStyle())
        .onAppear { selectedPage = startPage }
        .onChange(of: selectedPage) { _, page in
            if page != .microphone { micTest.stop() }
            if page == .permissions { permissions?.refresh() }
        }
        .onDisappear { micTest.stop() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(SettingsLook.secondary)
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(SettingsLook.card, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(returnLabel)
                Text("Settings").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsPage.visible) { page in
                        if let group = page.groupStart {
                            Text(group)
                                .font(.system(size: 10.5, weight: .semibold)).tracking(1)
                                .foregroundStyle(SettingsLook.tertiary)
                                .padding(.leading, 12).padding(.top, page == SettingsPage.visible.first ? 0 : 14).padding(.bottom, 4)
                        }
                        Button { selectedPage = page } label: {
                            HStack(spacing: 11) {
                                Image(systemName: page.symbol).font(.system(size: 13)).frame(width: 18)
                                Text(page.title).font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(selectedPage == page ? .white : SettingsLook.secondary)
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(selectedPage == page ? SettingsLook.selected : .clear,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.never)
            Text("ClickBait \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.system(size: 11)).foregroundStyle(SettingsLook.tertiary)
                .padding(.leading, 12).padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .background(SettingsLook.sidebar)
    }

    @ViewBuilder
    private var page: some View {
        switch selectedPage {
        case .general:
            if let health, health != .ready {
                SettingsGroup("Needs attention") {
                    ButtonRow(health.words, "ClickBait can't do everything until this is fixed.", button: "Fix") {
                        selectedPage = .permissions
                    }
                }
            }
            SettingsGroup("Behavior") {
                ToggleRow("Carry out spoken commands", "Say “open Safari”, “volume 30” or “dark mode” while holding ⌃⌥.", isOn: $settings.commandsEnabled)
                Divider().overlay(SettingsLook.hairline)
                ToggleRow("Morning suggestions", "Up to three things to ask each morning, from today's reminders and events.",
                          isOn: $settings.morningCards)
                    .onChange(of: settings.morningCards) { _, on in if on { MorningBrief.requestAccess() } }
                Divider().overlay(SettingsLook.hairline)
                ToggleRow("Greetings", "A hello by the cursor each time your Mac wakes or you unlock it.", isOn: $settings.greetings)
                Divider().overlay(SettingsLook.hairline)
                ToggleRow("Sounds", "A soft sound when a background ClickBait is done or needs your yes.", isOn: $settings.soundCues)
            }
            SettingsGroup("Vision Memory") {
                VisionMemorySection(settings: settings)
            }
            SettingsGroup("Notch") {
                ToggleRow("Notch panel", "Music, shelf, mirror and chat at the notch.",
                          isOn: Binding(get: { settings.notchPanelEnabled }, set: { menu?.setNotch($0) }))
                Divider().overlay(SettingsLook.hairline)
                ToggleRow("Volume in the notch", "The volume keys show Pac-Man's level instead of macOS's.", isOn: $settings.notchVolumeHUD)
                Divider().overlay(SettingsLook.hairline)
                ToggleRow("Brightness in the notch", "The brightness keys show the sky's time of day instead of macOS's.",
                          isOn: $settings.notchBrightnessHUD)
                Divider().overlay(SettingsLook.hairline)
                ToggleRow("Spotify covers always", "Download album art even with Internet Mode off.", isOn: $settings.spotifyArtworkAlways)
                Divider().overlay(SettingsLook.hairline)
                ToggleRow("YouTube thumbnails always", "Download the playing video's thumbnail even with Internet Mode off.",
                          isOn: $settings.youtubeThumbnailsAlways)
            }
            SettingsGroup("Your things") {
                LinkRow("Remembered", "What you asked ClickBait to remember.") { MemoryStore.shared.reveal() }
                Divider().overlay(SettingsLook.hairline)
                LinkRow("Notes folder", "Your .md notes that answers can use.") { MemoryStore.shared.revealNotes() }
                Divider().overlay(SettingsLook.hairline)
                LinkRow("Saved answers", "Answers you saved from the chat.") { AnswerArchive.reveal() }
            }
            SettingsGroup("ClickBait") {
                LinkRow("About ClickBait", "Version, licence and credits.", external: true) { menu?.openAbout() }
                Divider().overlay(SettingsLook.hairline)
                ButtonRow("Quit ClickBait", "The companion and notch go away until you open it again.", button: "Quit", destructive: true) { menu?.quit() }
            }
        case .shortcuts:
            SettingsGroup("Talk to ClickBait") {
                ForEach(Array(ShortcutList.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().overlay(SettingsLook.hairline) }
                    HStack(spacing: 12) {
                        RowLabel(item.title, item.detail)
                        Spacer(minLength: 12)
                        ShortcutKeys(item: item)
                    }
                    .settingsRow()
                }
            }
        case .commands:
            SettingsGroup("Spoken commands") {
                VStack(alignment: .leading, spacing: 10) { CommandsSettingsSection(settings: settings) }.settingsRow()
            }
        case .voice:
            SettingsGroup("Voice") {
                VStack(alignment: .leading, spacing: 10) { VoiceSettingsSection(settings: settings, speaker: speaker) }.settingsRow()
            }
        case .microphone:
            SettingsGroup("Input device") {
                RadioRow("System Default", selected: settings.microphoneUID == nil) { settings.microphoneUID = nil }
                ForEach(microphones) { device in
                    Divider().overlay(SettingsLook.hairline)
                    RadioRow(device.name, selected: settings.microphoneUID == device.id) { settings.microphoneUID = device.id }
                }
            }
            .onChange(of: settings.microphoneUID) { _, _ in if micTest.isRunning { micTest.start() } }
            .onAppear { microphones = Microphones.all() }
            SettingsGroup("Test") {
                HStack(spacing: 14) {
                    Button(micTest.isRunning ? "Stop" : "Test microphone") {
                        if micTest.isRunning { micTest.stop() } else { micTest.start() }
                    }
                    .buttonStyle(PillButtonStyle())
                    LevelBars(level: micTest.level)
                    Spacer()
                }
                .settingsRow()
            }
            Text(micTest.failure ?? "Speak normally: the bars move as ClickBait hears you. Nothing is kept.")
                .font(.system(size: 12)).foregroundStyle(micTest.failure == nil ? SettingsLook.tertiary : CompanionTone.problem)
                .padding(.leading, 4).padding(.top, -12)
        case .speech:
            SettingsGroup("Speech recognition") {
                VStack(alignment: .leading, spacing: 10) { SpeechModelSection(settings: settings, speech: speech) }.settingsRow()
            }
        case .aiModel:
            SettingsGroup("AI model") {
                VStack(alignment: .leading, spacing: 10) { ProviderSettingsSection(settings: settings) }.settingsRow()
            }
        case .internet:
            SettingsGroup("Internet Mode") {
                ToggleRow(settings.internet.isOn ? "On 🌐" : "Off 🔒",
                          "Free lookups when you ask. Gemini answers are a separate opt-in. Off every time ClickBait starts.",
                          isOn: Binding(get: { settings.internet.isOn },
                                        set: { if $0 != settings.internet.isOn { settings.internet.toggle() } }))
            }
            if !settings.internet.recent.isEmpty {
                SettingsGroup("Recent searches") {
                    ForEach(Array(settings.internet.recent.enumerated()), id: \.offset) { index, lookup in
                        if index > 0 { Divider().overlay(SettingsLook.hairline) }
                        Text(lookup).font(.system(size: 13)).lineLimit(1).settingsRow()
                    }
                }
            }
            SettingsGroup("Search source") {
                VStack(alignment: .leading, spacing: 10) { InternetSettingsSection(searxng: searxng) }.settingsRow()
            }
        case .permissions:
            SettingsGroup("macOS") {
                ForEach(Array(PermissionKind.allCases.enumerated()), id: \.offset) { index, kind in
                    if index > 0 { Divider().overlay(SettingsLook.hairline) }
                    permissionRow(kind)
                }
            }
            .task {
                // Follows a switch flipped in System Settings or Chrome while this page is open.
                while !Task.isCancelled {
                    permissions?.refresh()
                    chromeScripting = await ChromeJavaScriptSwitch.isOn()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            SettingsGroup("Browser") {
                ToggleRow("YouTube controls in Chrome",
                          chromeScripting == nil ? "Open Chrome, then switch this on: ClickBait ticks Chrome's own setting."
                              : "Play, pause, skip and the progress bar for YouTube in the notch.",
                          isOn: Binding(get: { chromeScripting == true }, set: { _ in toggleChrome() }))
                    .disabled(chromeScripting == nil)
            }
            Text("macOS only lets you change a permission in System Settings: switching one opens the right place.")
                .font(.system(size: 12)).foregroundStyle(SettingsLook.tertiary).padding(.leading, 4).padding(.top, -12)
        case .privacy:
            SettingsGroup("Never look at these apps") {
                VStack(alignment: .leading, spacing: 10) { BlocklistEditor(blocklist: $settings.blocklist) }.settingsRow()
            }
            SettingsGroup("Screen capture") {
                ToggleRow("Hide ClickBait in its screenshots", "Its own windows stay out of what it sees. Other apps' recordings are unchanged.",
                          isOn: $settings.ignoreNotchInCaptures)
            }
            SettingsGroup("Saved covers") {
                ButtonRow("\(savedCovers) cover\(savedCovers == 1 ? "" : "s") on this Mac",
                          "Kept from Internet Mode so the notch shows them offline.", button: "Clear", enabled: savedCovers > 0) {
                    CoverCache.clear()
                    savedCovers = 0
                }
                .onAppear { savedCovers = CoverCache.count }
            }
            SettingsGroup("Uninstall") {
                ButtonRow("Uninstall ClickBait", "Deletes its files, speech model and settings. Ollama stays.", button: "Uninstall…",
                          destructive: true) { Uninstaller.confirmAndRun() }
            }
        case .debugging:
            SettingsGroup("Debugging") {
                ToggleRow("Keep the last screenshot and recording", "Saved to a temporary folder; deleted when you turn this off.",
                          isOn: $settings.keepDebugCaptures)
                    .onChange(of: settings.keepDebugCaptures) { _, keep in if !keep { DebugCaptureStore.deleteAll() } }
                if settings.keepDebugCaptures {
                    Divider().overlay(SettingsLook.hairline)
                    LinkRow("Reveal last capture", "Opens it in Finder.") { menu?.revealLastCapture() }
                }
                #if DEBUG
                Divider().overlay(SettingsLook.hairline)
                ButtonRow("Test capsule", "Runs a local background job.", button: "Run") { menu?.runDebugCapsuleTest() }
                #endif
            }
        }
    }

    /// A permission as a switch showing what macOS has granted. On asks macOS (or opens the
    /// pane with the guide card); off opens the pane, where only the user can turn it off.
    private func permissionRow(_ kind: PermissionKind) -> some View {
        let granted = permissions?.status(of: kind) == .granted
        return ToggleRow(kind.title, kind.reason, symbol: kind.symbolName,
                         isOn: Binding(get: { granted },
                                       set: { on in if on { permissions?.request(kind) } else { permissions?.openSettings(for: kind) } }))
    }

    private func toggleChrome() {
        Task {
            _ = await ChromeJavaScriptSwitch.toggle()
            try? await Task.sleep(for: .milliseconds(300))
            chromeScripting = await ChromeJavaScriptSwitch.isOn()
        }
    }
}

extension SettingsView {
    static func status(_ status: BackgroundJob.Status) -> String {
        switch status {
        case .working: "Working"
        case .done: "Ready"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

/// HeyClicky's settings colours, as dark greys (ClickBait's accents stay its own).
enum SettingsLook {
    static let page = Color(hex: 0x19191B)
    static let sidebar = Color(hex: 0x1E1E21)
    static let card = Color.white.opacity(0.055)
    static let selected = Color.white.opacity(0.1)
    static let hairline = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.62)
    /// Descriptions and group names: 0.5 white reads at about 4.6:1 on the page (0.35 didn't).
    static let tertiary = Color.white.opacity(0.5)
    static let accent = AquaDark.link
}

/// A group: its name small, uppercase and grey, above a rounded card of rows.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(1)
                .foregroundStyle(SettingsLook.tertiary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(SettingsLook.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SettingsLook.hairline, lineWidth: 1))
        }
    }
}

extension View {
    /// A row's padding inside a card.
    func settingsRow() -> some View {
        padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A setting's name, and what it does in one grey line under it.
struct RowLabel: View {
    let title: String
    let detail: String
    var symbol: String?
    init(_ title: String, _ detail: String, symbol: String? = nil) { (self.title, self.detail, self.symbol) = (title, detail, symbol) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(SettingsLook.secondary).frame(width: 18).padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                Text(detail).font(.system(size: 12)).foregroundStyle(SettingsLook.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    var symbol: String?
    @Binding var isOn: Bool
    init(_ title: String, _ detail: String, symbol: String? = nil, isOn: Binding<Bool>) {
        (self.title, self.detail, self.symbol) = (title, detail, symbol)
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: 16) {
            RowLabel(title, detail, symbol: symbol)
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).labelsHidden().fixedSize().accessibilityLabel(title)
        }
        .settingsRow()
    }
}

/// A row ending in a white pill button ("Check for updates").
private struct ButtonRow: View {
    let title: String
    let detail: String
    let button: String
    var enabled = true
    var destructive = false
    let action: () -> Void
    init(_ title: String, _ detail: String, button: String, enabled: Bool = true, destructive: Bool = false, action: @escaping () -> Void) {
        (self.title, self.detail, self.button, self.enabled, self.destructive, self.action) = (title, detail, button, enabled, destructive, action)
    }

    var body: some View {
        HStack(spacing: 16) {
            RowLabel(title, detail)
            Spacer(minLength: 12)
            Button(button, action: action).buttonStyle(PillButtonStyle(destructive: destructive)).disabled(!enabled)
        }
        .settingsRow()
    }
}

/// A row that opens something: › for a place in ClickBait or Finder, ↗ for outside.
private struct LinkRow: View {
    let title: String
    let detail: String
    var external = false
    let action: () -> Void
    init(_ title: String, _ detail: String, external: Bool = false, action: @escaping () -> Void) {
        (self.title, self.detail, self.external, self.action) = (title, detail, external, action)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                RowLabel(title, detail)
                Spacer(minLength: 12)
                Image(systemName: external ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(SettingsLook.tertiary)
            }
            .settingsRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A choice in a list, ticked in a filled circle when chosen (the Microphone page).
private struct RadioRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    init(_ title: String, selected: Bool, action: @escaping () -> Void) { (self.title, self.selected, self.action) = (title, selected, action) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(SettingsLook.tertiary, lineWidth: 1.2).opacity(selected ? 0 : 1)
                    if selected {
                        Circle().fill(SettingsLook.accent)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                Spacer()
            }
            .settingsRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// HeyClicky's white pill ("Check for updates", "Test microphone"); red text when it destroys.
struct PillButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(destructive ? CompanionTone.problem : Color.black)
            .padding(.horizontal, 16).frame(height: 30)
            .background(Color.white.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
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
    /// The pages in the sidebar: debugging only in debug builds.
    static var visible: [SettingsPage] {
        #if DEBUG
        allCases
        #else
        allCases.filter { $0 != .debugging }
        #endif
    }

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
        case .aiModel: "AI model & Google key"
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
        case .aiModel: "Paste your Google AI Studio key and configure Gemini for Internet Mode."
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

    private var kokoroChosen: Bool { KokoroVoice.name(in: settings.voiceIdentifier) != nil }

    var body: some View {
        Toggle("Read answers aloud", isOn: $settings.speakAnswers)
        Picker("Voice", selection: $settings.voiceIdentifier) {
            Text("Automatic (best for your language)").tag(String?.none)
            Section("Kokoro — natural, English, on this Mac") {
                ForEach(KokoroVoice.offered, id: \.id) { voice in
                    Text(voice.title).tag(Optional(KokoroVoice.prefix + voice.id))
                }
            }
            Section("macOS voices") {
                ForEach(voices, content: Self.voiceRow)
            }
        }
        .disabled(!settings.speakAnswers)
        if kokoroChosen { KokoroDownloadRow() }
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

/// Vision Memory (user's asks, 2026-11-01): what ClickBait reads and describes in pictures,
/// and the user's control over it — on/off and pause, folders in and out, screenshots,
/// battery, the Photos library, "me", and what it all takes on disk.
struct VisionMemorySection: View {
    @Bindable var settings: AppSettings
    /// The last numbers shown: the page opens with them, not 0 of 0 while the index answers
    /// (it can be busy checking folders; user's report, 2026-11-02: "keeps going back to zero").
    @MainActor private static var lastStats: (pictures: Int, described: Int, bytes: Int, active: Bool) = (0, 0, 0, false)
    @State private var stats = VisionMemorySection.lastStats
    @State private var confirmDelete = false

    private var pausedNote: String? {
        if !settings.visionDescribe { return "off" }
        guard let until = settings.visionPausedUntil, until > Date() else { return nil }
        return "paused"
    }

    private var allDone: Bool { stats.pictures > 0 && stats.described >= stats.pictures }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow("Describe multimedia", "Reads your pictures and videos on this Mac (what they show, and any text) so smart search can find them by what's in them.",
                      isOn: $settings.visionDescribe)
            Divider().overlay(SettingsLook.hairline)
            // Progress, and pausing: one row, like the others.
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    RowLabel("\(stats.described.formatted()) of \(stats.pictures.formatted()) pictures and videos described",
                             (stats.active && pausedNote == nil ? "Describing now · " : "")
                                + ByteCountFormatter.string(fromByteCount: Int64(stats.bytes), countStyle: .file) + " on disk"
                                + (pausedNote.map { " · " + $0 } ?? ""))
                    ProgressView(value: Double(stats.described), total: Double(max(stats.pictures, 1)))
                        .progressViewStyle(.linear).tint(SettingsLook.accent).frame(maxWidth: 260)
                }
                Spacer(minLength: 12)
                // One button (user's ask, 2026-11-01): Pause while learning, Learn while
                // paused, Done! once every picture is described.
                if allDone {
                    Button("Done!") {}.buttonStyle(PillButtonStyle()).disabled(true)
                } else if pausedNote != nil, settings.visionDescribe {
                    Button("Learn") { settings.visionPausedUntil = nil }.buttonStyle(PillButtonStyle())
                } else {
                    Button("Pause") { settings.visionPausedUntil = .distantFuture }.buttonStyle(PillButtonStyle())
                        .disabled(!settings.visionDescribe)
                }
            }
            .settingsRow()
            Divider().overlay(SettingsLook.hairline)
            FolderList(title: "Folders it reads", detail: "Pictures in these folders, and the folders inside them.",
                       folders: $settings.visionFolders, add: "Add…", empty: "No folders: only the Photos library, if it's on.")
            Divider().overlay(SettingsLook.hairline)
            FolderList(title: "Never look in", detail: "Left out completely, including from search results.",
                       folders: $settings.visionExcluded, add: "Exclude…", empty: "Nothing excluded.")
            Divider().overlay(SettingsLook.hairline)
            ToggleRow("Screenshots and documents", "Also describe screenshots, charts and documents. Text that looks like a password, card or ID number is never kept either way.",
                      isOn: $settings.visionScreenshots)
            Divider().overlay(SettingsLook.hairline)
            ToggleRow("Work on battery", "Off: only while plugged in. It always waits while you're asking ClickBait something, in Low Power Mode, or when the Mac is hot.",
                      isOn: $settings.visionOnBattery)
            Divider().overlay(SettingsLook.hairline)
            ToggleRow("Search the Photos library", "“Find the picture of the airport” also looks in Photos (not its Hidden album). All on this Mac.",
                      isOn: $settings.searchPhotos)
                .onChange(of: settings.searchPhotos) { _, on in
                    guard on else { return }
                    let options = settings.visionOptions
                    Task {
                        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                        await SearchIndex.shared.refresh(options)
                    }
                }
            Divider().overlay(SettingsLook.hairline)
            YourPhotoRow(settings: settings)
            Divider().overlay(SettingsLook.hairline)
            ButtonRow("Delete Vision Memory", "Everything read and described; your pictures and videos aren't touched. To fix one picture, right-click it in search results.",
                      button: "Delete…", destructive: true) { confirmDelete = true }
        }
        // Live while the page is open: the count moves as pictures are described.
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: settings.visionFolders) { _, _ in AppDelegate.watchPictures(settings); refreshSoon() }
        .onChange(of: settings.visionExcluded) { _, _ in refreshSoon() }
        .confirmationDialog("Delete everything Vision Memory has read and described?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task { await SearchIndex.shared.forgetAll(); await reload() }
            }
        } message: {
            Text("Your pictures aren't touched. Smart search starts over, reading them again at the next pass unless you turn Describe pictures off.")
        }
    }

    private func reload() async {
        stats = await SearchIndex.shared.stats()
        Self.lastStats = stats
    }

    private func refreshSoon() {
        let options = settings.visionOptions
        Task { await SearchIndex.shared.refresh(options, quick: true); await reload() }
    }
}

/// A setting row with its folders listed in an inset box under it: a remove button on each,
/// "Add…" (an open panel) on the row.
private struct FolderList: View {
    let title: String
    let detail: String
    @Binding var folders: [String]
    let add: String
    let empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                RowLabel(title, detail)
                Spacer(minLength: 12)
                Button(add) { choose() }.buttonStyle(PillButtonStyle())
            }
            VStack(spacing: 0) {
                if folders.isEmpty {
                    Text(empty).font(.system(size: 12)).foregroundStyle(SettingsLook.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                }
                ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                    if index > 0 { Divider().overlay(SettingsLook.hairline) }
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(SettingsLook.accent)
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12.5)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { folders.removeAll { $0 == folder } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(SettingsLook.secondary)
                                .frame(width: 18, height: 18).background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain).help("Remove \((folder as NSString).lastPathComponent)")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SettingsLook.hairline, lineWidth: 1))
        }
        .settingsRow()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.openFromNotch { urls in
            for url in urls where !folders.contains(url.path) { folders.append(url.path) }
        }
    }
}

/// Smart search's "me": one photo of the user, so "a picture where I'm holding a dog" finds them.
private struct YourPhotoRow: View {
    let settings: AppSettings
    @State private var isSet = YourFace.isSet
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 16) {
            RowLabel("Your photo, for “me”",
                     problem ?? (isSet ? "Set. “Find a picture of me…” looks for your face. Stays on this Mac."
                                       : "Pick a clear photo of your face, so “find a picture of me…” knows who you are."))
            Spacer(minLength: 12)
            if isSet {
                Button("Remove") { YourFace.clear(); isSet = false; reindex() }.buttonStyle(PillButtonStyle(destructive: true))
            }
            Button(isSet ? "Change…" : "Choose…") { choose() }.buttonStyle(PillButtonStyle())
        }
        .settingsRow()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Pick a photo of yourself (your face clear and big)."
        panel.openFromNotch { urls in
            guard let url = urls.first else { return }
            if YourFace.setReference(from: url) {
                isSet = true
                problem = nil
                reindex()
            } else {
                problem = "No face found in that photo. Try one where your face is clear."
            }
        }
    }

    /// Pictures are read again so their faces are compared with the new photo.
    private func reindex() {
        let options = settings.visionOptions
        Task {
            await SearchIndex.shared.forgetPictures()
            await SearchIndex.shared.refresh(options)
        }
    }
}

/// Kokoro's one-time download, shown once a Kokoro voice is picked.
private struct KokoroDownloadRow: View {
    @State private var download = KokoroDownload.shared
    @State private var installed = KokoroVoice.isInstalled

    var body: some View {
        if let fraction = download.fraction {
            ProgressView(value: fraction) { Text("Downloading Kokoro…") }
        } else if !installed {
            HStack {
                Text("Kokoro voices need a one-time download (340 MB). Until then, the Mac's voice speaks.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Download") { download.start() }
            }
        }
        if let problem = download.problem {
            Text(problem).font(.callout).foregroundStyle(.orange)
        }
        Color.clear.frame(height: 0)
            .onChange(of: download.fraction) { _, now in if now == nil { installed = KokoroVoice.isInstalled } }
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
