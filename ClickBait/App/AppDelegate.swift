import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplication.delegate is weak, so the delegate is kept alive here.
    private static var shared: AppDelegate?

    private let settings = AppSettings()
    private let permissions = PermissionsManager()
    private lazy var speech = SpeechModelManager(settings: settings)
    private lazy var coordinator = AskCoordinator(settings: settings, speech: speech)
    private lazy var hotkey = HotkeyMonitor { [weak self] event in self?.coordinator.handle(event) }
    private var statusBar: StatusBarController?
    private let overlay = OverlayController()
    private lazy var settingsWindow = SettingsWindowController(settings: settings, speech: speech, speaker: coordinator.speaker)
    private lazy var onboardingWindow = OnboardingWindowController(permissions: permissions, settings: settings, speech: speech)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherInstances()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.app.notice("ClickBait \(version, privacy: .public) launched")

        let statusBar = StatusBarController(
            settings: settings,
            onOpenSettings: { [weak self] in self?.settingsWindow.show() },
            onOpenPermissions: { [weak self] in self?.onboardingWindow.show() }
        )
        self.statusBar = statusBar
        overlay.trailEnabled = { [weak self] in self?.settings.speedTrail ?? false }
        overlay.start()
        overlay.onDismiss = { [weak self] in self?.coordinator.answerDismissed() }
        overlay.onCancel = { [weak self] in self?.coordinator.cancelInFlight() }
        coordinator.onStateChange = { [weak self, weak statusBar] state in
            statusBar?.update(for: state)
            self?.overlay.show(state)
        }
        coordinator.onTranscript = { [weak self, weak statusBar] text in
            statusBar?.showHeard(text)
            self?.overlay.show(.thinking, heard: text)
        }
        coordinator.onExplaining = { [weak self] selected in self?.overlay.showExplaining(selected) }
        coordinator.onPartialAnswer = { [weak self] partial in self?.overlay.showPartialAnswer(partial) }
        coordinator.onSpeechFinished = { [weak self] in self?.overlay.speechFinished() }
        coordinator.onActionDone = { [weak self] message in self?.overlay.showDone(message) }
        coordinator.onAnswer = { [weak self, weak statusBar] response, pointers in
            statusBar?.showAnswer(response.speech, pointers: pointers.map { "\($0.label) at \($0.quartz)" })
            guard let self else { return }
            overlay.showAnswer(response.speech, pointers: pointers, waitForSpeech: coordinator.willSpeak && coordinator.speaker.isSpeaking)
        }
        hotkey.start()
        speech.loadIfInstalled()

        logPermissions()
        if onboardingWindow.shouldShowAtLaunch {
            onboardingWindow.show()
        }
    }

    /// Two copies would mean two menu bar icons and two hotkey listeners. The newest
    /// launch wins, so Xcode's ⌘R replaces an already-running build.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != currentPID {
            app.terminate()
        }
    }

    private func logPermissions() {
        for kind in PermissionKind.allCases {
            Log.app.notice("Permission \(kind.title, privacy: .public): \(String(describing: self.permissions.status(of: kind)), privacy: .public)")
        }
    }
}
