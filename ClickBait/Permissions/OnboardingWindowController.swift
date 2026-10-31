import AppKit
import ClickBaitCore
import SwiftUI

/// The setup window: one step at a time (welcome, microphone, Accessibility, Screen
/// Recording, the AI model, the speech model, then "meet ClickBait"), Clicky-style
/// (user's ask, 2026-10-25). Shown at launch until setup has been finished once, then
/// while a permission or the speech model is missing (unless the user opts out); also from
/// the menu bar's "Permissions…" item. Reopened after Screen Recording, it carries on.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let suppressAtLaunchKey = "onboarding.suppressAtLaunch"
    static let welcomedKey = "onboarding.welcomed"
    static let finishedKey = "onboarding.finished"

    private let permissions: PermissionsManager
    private let speech: SpeechModelManager
    private let model: ModelSetupChecker

    init(permissions: PermissionsManager, settings: AppSettings, speech: SpeechModelManager) {
        self.permissions = permissions
        self.speech = speech
        model = ModelSetupChecker(settings: settings)
        // The notch's look, Taby's flow (user's ask, 2026-11-01): a black island hanging from
        // the top of the screen, the bean in hyperspace on its left, the step on its right.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OnboardingView.size.width, height: OnboardingView.size.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to ClickBait"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        [.miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(
            permissions: permissions,
            settings: settings,
            speech: speech,
            model: model,
            onDone: { [weak self] in self?.close() }
        ))
        Self.hang(window)
    }

    /// Centred at the top of the main screen, just under the menu bar, like the open notch.
    private static func hang(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return window.center() }
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2, y: screen.visibleFrame.maxY - frame.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var shouldShowAtLaunch: Bool {
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: "onboarding.hasLaunched")
        UserDefaults.standard.set(true, forKey: "onboarding.hasLaunched")
        if isFirstLaunch { return true }
        if !UserDefaults.standard.bool(forKey: Self.finishedKey) { return true }
        let incomplete = !permissions.allGranted || speech.state == .notDownloaded
        return incomplete && !UserDefaults.standard.bool(forKey: Self.suppressAtLaunchKey)
    }

    func show() {
        permissions.refresh()
        permissions.startPolling()
        model.startPolling()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        permissions.stopPolling()
        model.stopPolling()
    }
}

struct OnboardingView: View {
    let permissions: PermissionsManager
    let settings: AppSettings
    let speech: SpeechModelManager
    let model: ModelSetupChecker
    let onDone: () -> Void

    @AppStorage(OnboardingWindowController.suppressAtLaunchKey) private var suppressAtLaunch = false
    @AppStorage(OnboardingWindowController.welcomedKey) private var welcomed = false
    @AppStorage(OnboardingWindowController.finishedKey) private var finished = false
    @State private var step: OnboardingStep?
    @State private var hello: String?
    /// The notch has shown itself, and ClickBait has heard the user (the two "try it" steps).
    @AppStorage("onboarding.notchSeen") private var notchSeen = false
    @AppStorage("onboarding.heardHello") private var heardHello = false
    @State private var heard: String?
    @State private var download = BrainDownload.shared

    /// `startAt`: a step to open on (renders); nil, where setup left off.
    init(permissions: PermissionsManager, settings: AppSettings, speech: SpeechModelManager, model: ModelSetupChecker,
         startAt: OnboardingStep? = nil, onDone: @escaping () -> Void) {
        self.permissions = permissions
        self.settings = settings
        self.speech = speech
        self.model = model
        self.onDone = onDone
        _step = State(initialValue: startAt)
    }

    private var done: Set<OnboardingStep> {
        var done: Set<OnboardingStep> = []
        if permissions.status(of: .microphone) == .granted { done.insert(.microphone) }
        if permissions.status(of: .accessibility) == .granted { done.insert(.accessibility) }
        if permissions.status(of: .screenRecording) == .granted { done.insert(.screenRecording) }
        if model.isReady { done.insert(.model) }
        if speech.isReady { done.insert(.speech) }
        if notchSeen || !settings.notchPanelEnabled { done.insert(.notch) }
        if heardHello { done.insert(.hello) }
        return done
    }

    var body: some View {
        let current = step ?? OnboardingStep.start(welcomed: welcomed, done: done)
        HStack(spacing: 12) {
            beanCard(current)
            stepCard(current)
        }
        .padding(EdgeInsets(top: 34, leading: 14, bottom: 14, trailing: 14))
        .onReceive(NotificationCenter.default.publisher(for: .clickBaitNotchShown)) { _ in notchSeen = true }
        .onReceive(NotificationCenter.default.publisher(for: .clickBaitHeard)) { note in
            heard = note.object as? String
            heardHello = true
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: current)
        // A permission just granted: on to the next step by itself.
        .onChange(of: done) { old, new in
            guard let step = step ?? Optional(current), step != .model, step != .speech,
                  new.contains(step), !old.contains(step) else { return }
            Task { try? await Task.sleep(for: .seconds(0.8)); if self.step == step || self.step == nil { self.step = step.next } }
        }
    }

    static let size = CGSize(width: 900, height: 520)

    /// The bean in hyperspace, its face for the step: hello, curious through the permissions,
    /// thinking while its brain downloads, listening for the voice, happy at the end.
    private func beanCard(_ current: OnboardingStep) -> some View {
        let mood: Bean.Mood = switch current {
        case .welcome: .hello
        case .model: model.isReady ? .happy : .thinking
        case .speech, .hello: .listening
        case .ready: .happy
        default: .idle
        }
        return ZStack {
            SpaceScene()
            NotchBean(mood: mood, size: 120, badge: false, awake: true)
        }
        .frame(width: 290)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHidden(true)
    }

    private func stepCard(_ current: OnboardingStep) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                dots(current)
                Spacer()
                // The brain keeps downloading while setup goes on: its progress on every step.
                if let brain = download.brain, current != .model {
                    HStack(spacing: 6) {
                        ProgressView(value: download.fraction ?? 0).frame(width: 60)
                        Text(small("\(brain.name) \(Int((download.fraction ?? 0) * 100))%")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ScrollView(showsIndicators: false) {
                Group {
                    switch current {
                    case .welcome: welcome
                    case .microphone: permission(.microphone)
                    case .accessibility: permission(.accessibility)
                    case .screenRecording: permission(.screenRecording)
                    case .model: modelStep
                    case .speech: speechStep
                    case .notch: notchStep
                    case .hello: helloStep
                    case .ready: ready
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer(current)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.078, green: 0.082, blue: 0.094), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Meet ClickBait")
            line("A little triangle that lives by your cursor. Ask about anything on your screen. It all runs on this Mac.")
            line("Setup takes a few minutes: three permissions and two downloads.")
        }
    }

    private func permission(_ kind: PermissionKind) -> some View {
        let status = permissions.status(of: kind)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbolName).font(.title).foregroundStyle(.tint).accessibilityHidden(true)
                title(kind.title)
            }
            line(kind.reason)
            if kind == .accessibility || kind == .screenRecording {
                line("System Settings opens with a small ClickBait card beside it: drag the card into the list and turn ClickBait on.")
            }
            if status == .granted {
                tick("allowed")
            } else {
                Button(small(status == .notDetermined && kind == .microphone ? "Allow" : "Open System Settings")) { permissions.request(kind) }
                    .controlSize(.large)
            }
            if kind == .screenRecording {
                line("macOS may ask you to quit and reopen ClickBait after this. Reopen it here, and setup carries on where you left off.")
                Button(small("Reopen ClickBait")) { Self.reopen() }
            }
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Choose your brain")
            line("ClickBait thinks with a model that runs on this Mac through Ollama, a free app. Answers never leave your Mac.")
            switch model.state {
            case .checking:
                ProgressView().controlSize(.small)
            case .noOllama:
                let installed = AppLocator.installed()["Ollama"]
                line(installed == nil ? "First install Ollama. ClickBait notices when it's running and carries on."
                                      : "Ollama is installed but not running. Open it and ClickBait carries on.")
                if let installed {
                    Button(small("Open Ollama")) { NSWorkspace.shared.openApplication(at: installed, configuration: .init()) }
                        .controlSize(.large)
                } else {
                    Button(small("Get Ollama")) { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
                        .controlSize(.large)
                }
            case .ready, .missingModel:
                // The four brains with this Mac's memory and disk; picking one downloads it
                // (it carries on while setup moves on) and switches to it.
                BrainPicker(settings: settings)
                if model.state == .ready { tick("your brain is ready") }
            }
        }
    }

    private var speechStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Hearing you")
            line("A speech model turns what you say into words, on this Mac.")
            SpeechModelSection(settings: settings, speech: speech, showsPicker: false)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(done.count == 7 ? "Try your first question" : "Almost there")
            if done.count < 7 {
                line("Still to do: " + missing.joined(separator: ", ") + ". ClickBait works without them, with less.")
            }
            if let hello { line("“\(hello)”").italic() } else if model.isReady { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 8) {
                shortcut("⌃⌥", "Hold Control+Option, ask out loud, let go")
                shortcut("fn ⌃", "Hold fn+Control to type what you say into any app")
                shortcut("▔", "The notch at the top of your screen: music, your shelf, settings")
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            line("Tap one, and ClickBait asks it for you, right here.")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["where's the share button?", "what can you do?", "what's on my screen?"], id: \.self) { question in
                    Button { NotificationCenter.default.post(name: .clickBaitAskFromSetup, object: question) } label: {
                        Text("“\(question)”").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isReady)
                }
                if !model.isReady { line(download.brain == nil ? "These work once your brain is ready." : "Your brain is still downloading.") }
            }
        }
        .task(id: model.isReady) {
            guard model.isReady, hello == nil else { return }
            hello = await OllamaSetup.hello(model.model)
        }
    }

    private var missing: [String] {
        [(OnboardingStep.model, "your brain"), (.microphone, "the microphone"), (.accessibility, "Accessibility"),
         (.screenRecording, "Screen Recording"), (.speech, "the speech model"), (.notch, "the notch"), (.hello, "saying hello")]
            .filter { !done.contains($0.0) }.map(\.1)
    }

    /// Point at the top of the screen and the notch peeks; it ticks once it has.
    private var notchStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("I live in your notch too")
            line("Point at the top of your screen. I peek out; stay a moment and I open: what's playing, the shelf for files, the mirror, a quick ask.")
            Toggle(small("Use the notch"), isOn: Binding(get: { settings.notchPanelEnabled }, set: { settings.notchPanelEnabled = $0 }))
            if notchSeen { tick("you found it") }
        }
    }

    /// Hold ⌃⌥ and say hello: ClickBait listens for real, and this ticks once it heard you.
    private var helloStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Say hello")
            line("Hold these two keys, say “hello”, let go.")
            HStack(spacing: 10) {
                ForEach(["⌃", "⌥"], id: \.self) { key in
                    Text(key).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color(red: 1, green: 0.46, blue: 0.09), in: RoundedRectangle(cornerRadius: 12))
                }
                Text(small("Control + Option")).foregroundStyle(.secondary)
            }
            if heardHello { tick(heard.map { "heard: “\($0)”" } ?? "I heard you") }
            else if !speech.isReady { line("The speech model isn't ready yet: go back a step to get it.") }
        }
    }

    // MARK: Pieces

    private func dots(_ current: OnboardingStep) -> some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == current ? Color.accentColor : done.contains(step) ? Color.green.opacity(0.7) : Color.secondary.opacity(0.25))
                    .frame(width: step == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func footer(_ current: OnboardingStep) -> some View {
        HStack {
            if current == .welcome || current == .ready {
                Toggle(small("Don't show this at launch"), isOn: $suppressAtLaunch).disabled(done.count == 7)
            } else {
                Button(small("Back")) { step = current.previous }
            }
            Spacer()
            switch current {
            case .welcome:
                Button(small("Let's set it up")) { welcomed = true; step = .model }.keyboardShortcut(.defaultAction)
            case .ready:
                Button(small("Done")) { finished = true; onDone() }.keyboardShortcut(.defaultAction)
            default:
                Button(small(done.contains(current) || current == .model && model.downloading ? "Continue" : "Skip for now")) {
                    welcomed = true
                    step = current.next
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(small(text)).font(.title2.bold())
    }

    private func line(_ text: String) -> Text {
        Text(small(text)).font(.body).foregroundStyle(.secondary)
    }

    private func tick(_ text: String) -> some View {
        Label(small(text), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
    }

    private func shortcut(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(keys).font(.system(.body, design: .rounded).bold()).frame(width: 44, alignment: .leading)
            Text(small(text)).foregroundStyle(.secondary)
        }
    }

    /// Setup reads in small letters, names kept, like the pills (user's ask, 2026-10-25).
    private func small(_ text: String) -> String { PillCase.lowered(text, names: AppLocator.pillNames) }

    /// Quits and opens ClickBait again (Screen Recording only takes effect after a relaunch).
    static func reopen() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    /// The notch peeked or opened (setup's notch step ticks).
    static let clickBaitNotchShown = Notification.Name("ClickBait.notchShown")
    /// A voice question was heard; its words are the object (setup's "say hello" ticks).
    static let clickBaitHeard = Notification.Name("ClickBait.heard")
    /// Setup's last step asks a suggested question for real; the text is the object.
    static let clickBaitAskFromSetup = Notification.Name("ClickBait.askFromSetup")
}
