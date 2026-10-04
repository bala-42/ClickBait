import ClickBaitCore
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
    private let chat = ChatController()
    private let confirm = ConfirmController()
    private let escape = InputInterceptor()
    private lazy var tutorial = TutorialController(overlay: overlay)
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

    /// Lets Ollama free the models it kept loaded for ClickBait.
    func applicationWillTerminate(_ notification: Notification) {
        (settings.makeProvider() as? OllamaProvider)?.unload()
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
        overlay.start()
        overlay.onDismiss = { [weak self] in self?.coordinator.answerDismissed() }
        // Esc in other apps: taken only while ClickBait is busy, so it never reaches
        // both. Esc typed in ClickBait's own chat comes through overlay.onEscape below.
        escape.isBusy = { [weak self] in
            guard let self else { return false }
            return coordinator.isBusy || overlay.isGuiding || confirm.isShowing
        }
        escape.onEscape = { [weak self] in _ = self?.overlay.onEscape?() }
        escape.onTypeToAsk = { [weak self] in self?.coordinator.startTypedChat() }
        coordinator.onChatOpenForTyping = { [weak self] in
            guard let self else { return }
            overlay.endGuide()
            let mouse = NSEvent.mouseLocation
            chat.openForTyping(at: CGPoint(x: mouse.x + 12, y: mouse.y - 12))
        }
        coordinator.onChatFocus = { [weak self] in self?.chat.focus() }
        escape.start()

        // Esc, in layers: stop what's happening; else stop pointing; else close the chat.
        overlay.onEscape = { [weak self] in
            guard let self else { return false }
            if coordinator.stopActivity() {
                overlay.endGuide()
                overlay.dismissAnswer()
                return true
            }
            if overlay.isGuiding {
                overlay.endGuide()
                return true
            }
            guard chat.isOpen else { return false }
            closeChat()
            return true
        }
        chat.companionPoint = { NSEvent.mouseLocation }  // the companion rides the cursor
        chat.model.onSend = { [weak self] text in self?.coordinator.sendTyped(text) }
        chat.model.onClose = { [weak self] in self?.closeChat() }
        coordinator.onChatOpen = { [weak self] firstMessage in
            guard let self else { return }
            overlay.endGuide()
            chat.open(at: overlay.companionTopLeft)
            chat.model.addUser(firstMessage)
            chat.model.isBusy = true
        }
        coordinator.onChatUserMessage = { [weak self] message in
            self?.overlay.endGuide()
            self?.chat.model.addUser(message)
            self?.chat.model.isBusy = true
        }
        confirm.onAnswer = { [weak self] yes in self?.coordinator.answerConfirmation(yes) }
        coordinator.onConfirmRequest = { [weak self] question in
            guard let self else { return }
            confirm.show(question, at: overlay.companionTopLeft)
        }
        coordinator.onConfirmEnd = { [weak self] in self?.confirm.hide() }
        coordinator.onStopped = { [weak self] in
            guard let self, chat.isOpen, chat.model.isBusy else { return }
            chat.model.setAssistant(chat.model.messages.last?.role == .assistant ? (chat.model.messages.last?.text ?? "") + " …(stopped)" : "Stopped.")
            chat.model.isBusy = false
        }
        coordinator.onChatReply = { [weak self] text in
            self?.chat.model.setAssistant(text)
            self?.chat.model.isBusy = false
        }
        coordinator.onChatError = { [weak self] message in
            self?.chat.model.addError(message)
            self?.chat.model.isBusy = false
        }
        coordinator.onChatClose = { [weak self] in
            self?.overlay.endGuide()
            self?.chat.close()
        }
        coordinator.onStateChange = { [weak self, weak statusBar] state in
            statusBar?.update(for: state)
            self?.overlay.show(state)
        }
        coordinator.onTranscript = { [weak self, weak statusBar] text in
            statusBar?.showHeard(text)
            self?.overlay.show(.thinking, heard: text)
        }
        coordinator.tutorial = tutorial
        overlay.onClick = { [weak self] point in self?.tutorial.noteClick(point) }
        tutorial.speak = { [weak self] text in self?.coordinator.speaker.speak(text) }
        tutorial.onChecklist = { [weak self] text in
            guard let self, chat.isOpen else { return }
            chat.model.replaceLastAssistant(text)
            chat.model.isBusy = false
        }
        coordinator.onSetupFinished = { [weak self] in self?.overlay.clearWorking() }
        tutorial.onFinished = { [weak self] message in
            guard let self, let message else { return }
            // A tutorial that opened another app offers the way back (ignored = stay).
            if message == "Done!", let home = coordinator.tutorialReturnApp, !home.isTerminated,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != home.processIdentifier {
                confirm.show("done! back to \(home.localizedName ?? "where you were")?", at: overlay.companionTopLeft,
                             confirm: "Back", cancel: "Stay", hint: nil, tone: .tutorial) { back in
                    if back { home.activate() }
                }
            }
            if chat.isOpen, let last = chat.model.messages.last(where: { $0.role == .assistant }) {
                chat.model.replaceLastAssistant(last.text + "\n\n" + message)
            } else if message != "Done!" {
                overlay.show(.error(message))
            }
        }
        coordinator.onTour = { [weak self] parts in self?.overlay.tour(parts) }
        coordinator.onPointersRefined = { [weak self] pointers in self?.overlay.retarget(pointers) }
        coordinator.onInstantPointer = { [weak self] pointers in self?.overlay.guide(to: pointers) }
        overlay.levelSource = { [weak coordinator] in coordinator?.microphoneLevel ?? 0 }
        coordinator.onSnipMarking = { [weak self] marking in self?.overlay.setSnipping(marking) }
        coordinator.onExplaining = { [weak self] selected in self?.overlay.showExplaining(selected) }
        coordinator.onPartialAnswer = { [weak self] partial in self?.chat.model.setAssistant(partial) }
        coordinator.onActionStarted = { [weak self] message in self?.overlay.showWorking(message) }
        coordinator.onActionDone = { [weak self] message in self?.overlay.showDone(message) }
        coordinator.onAnswer = { [weak self, weak statusBar] response, pointers in
            statusBar?.showAnswer(response.speech, pointers: pointers.map { "\($0.label) at \($0.quartz)" })
            guard let self else { return }
            if chat.isOpen {
                chat.model.setAssistant(response.displayText)  // final text, with any code as a block
                chat.model.isBusy = false
            }
            // Already pointing (instantly, before the model): don't start over.
            if !coordinator.pointedInstantly { overlay.guide(to: pointers) }
        }
        hotkey.start()
        TextReader.warmUp()
        // Models load now and stay loaded while ClickBait runs (no reload after a break).
        let provider = settings.makeProvider()
        Task.detached(priority: .utility) { await provider.warmUp() }
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

    /// ✕ or Escape on the chat bubble: close it and forget the conversation.
    private func closeChat() {
        coordinator.closeChat()
        overlay.endGuide()
        chat.close()
    }
}
