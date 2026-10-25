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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to ClickBait"
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
        window.center()
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
        return done
    }

    var body: some View {
        let current = step ?? OnboardingStep.start(welcomed: welcomed, done: done)
        VStack(alignment: .leading, spacing: 18) {
            dots(current)
            Group {
                switch current {
                case .welcome: welcome
                case .microphone: permission(.microphone)
                case .accessibility: permission(.accessibility)
                case .screenRecording: permission(.screenRecording)
                case .model: modelStep
                case .speech: speechStep
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer(current)
        }
        .padding(24)
        .frame(width: 520, height: 480)
        .animation(.easeInOut(duration: 0.2), value: current)
        // A permission just granted: on to the next step by itself.
        .onChange(of: done) { old, new in
            guard let step = step ?? Optional(current), step != .model, step != .speech,
                  new.contains(step), !old.contains(step) else { return }
            Task { try? await Task.sleep(for: .seconds(0.8)); if self.step == step || self.step == nil { self.step = step.next } }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Meet ClickBait")
            line("A helper that lives by your cursor. Hold Control+Option and ask about anything on your screen: it answers, points at what to click, or walks you through it step by step.")
            line("Everything runs on this Mac. No account, and nothing you say or show leaves it.")
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
            title("The AI model")
            line("ClickBait thinks with Gemma, a model that runs on your Mac through Ollama, a free app.")
            switch model.state {
            case .checking:
                ProgressView().controlSize(.small)
            case .ready:
                tick("Gemma is ready")
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
            case .missingModel:
                if model.downloading {
                    ProgressView(value: model.downloaded ?? 0)
                    line(model.downloaded.map { "Downloading Gemma… \(Int($0 * 100))%. It keeps going while you carry on." }
                         ?? "Starting the download…")
                } else {
                    line("Download Gemma: about 6.6 GB, once. It can download while you finish setup.")
                    if let problem = model.downloadProblem { line(problem).foregroundStyle(.red) }
                    Button(small(model.downloadProblem == nil ? "Download Gemma" : "Try again")) { model.startDownload() }
                        .controlSize(.large)
                }
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
            title(done.count == 5 ? "You're set" : "Almost there")
            if done.count < 5 {
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
            line("Try it now: hold Control+Option and ask “what's on my screen?”")
        }
        .task(id: model.isReady) {
            guard model.isReady, hello == nil else { return }
            hello = await OllamaSetup.hello(model.model)
        }
    }

    private var missing: [String] {
        [(OnboardingStep.microphone, "the microphone"), (.accessibility, "Accessibility"), (.screenRecording, "Screen Recording"),
         (.model, "the AI model"), (.speech, "the speech model")].filter { !done.contains($0.0) }.map(\.1)
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
                Toggle(small("Don't show this at launch"), isOn: $suppressAtLaunch).disabled(done.count == 5)
            } else {
                Button(small("Back")) { step = current.previous }
            }
            Spacer()
            switch current {
            case .welcome:
                Button(small("Let's set it up")) { welcomed = true; step = .microphone }.keyboardShortcut(.defaultAction)
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
