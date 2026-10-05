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
    /// The "let's see! / later." pill is up.
    private var readyPillShown = false
    /// Where the companion was at the last hotkey press: the chat's place.
    private var invokedPoint: CGPoint?
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
            chat.openForTyping(logoAt: invokedPoint ?? overlay.companionTriangleCenter)
        }
        coordinator.onChatFocus = { [weak self] in
            // Focus first: it re-homes the chat to the app in front and shows it there.
            self?.chat.focus()
            self?.chat.untuck()
        }
        // The chat belongs to the app it was summoned in: away while another app is in
        // front, back (where it was) when that app is.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                // A walkthrough switching apps takes the chat (its checklist) along.
                if self.tutorial.isActive || self.overlay.isTutoring || self.coordinator.isOpeningAppForTutorial {
                    self.chat.adopt(app)
                } else {
                    self.chat.appActivated(app)
                }
            }
        }
        // Two pills: "answer's ready in Safari" rides with the companion; below it, where
        // it appeared, [let's see!] [later.] stays put. Both fade if ignored.
        chat.onReadyWhileAway = { [weak self] appName in
            guard let self else { return }
            overlay.showShortAnswer("answer's ready in \(appName)")
            guard !confirm.isShowing else { return }  // never over a question being asked
            let below = overlay.companionTopLeft
            readyPillShown = true
            confirm.show("", at: CGPoint(x: below.x, y: below.y - 30), confirm: "let's see!", cancel: "later.",
                         hint: nil, tone: .idle, waitTime: .seconds(10)) { [weak self] seeIt in
                guard let self else { return }
                readyPillShown = false
                if seeIt {
                    overlay.clearShortAnswer()  // both pills go
                    chat.homeApp?.activate()  // the chat is there, where it was
                }
            }
        }
        // Went back on their own: the offer has done its job.
        chat.onBackHome = { [weak self] in
            guard let self, readyPillShown else { return }
            readyPillShown = false
            confirm.hide()
        }
        coordinator.onInvoked = { [weak self] in
            guard let self else { return }
            let point = overlay.companionTriangleCenter
            invokedPoint = point
            chat.invoked(at: point)
        }
        escape.start()

        // Esc, in layers: stop what's happening; else stop pointing; else close the chat.
        overlay.onEscape = { [weak self] in
            guard let self else { return false }
            if readyPillShown {  // Esc on "let's see! / later." means later.
                readyPillShown = false
                confirm.hide()
                return true
            }
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
        chat.companionPoint = { [weak self] in self?.overlay.companionTriangleCenter ?? NSEvent.mouseLocation }
        chat.model.onSend = { [weak self] text in
            guard let self else { return }
            // Out of the way the moment Enter is pressed, before thinking starts (it used to
            // wait ~1–2 s, until the message had been sorted).
            chat.tuck()
            coordinator.sendTyped(text)
            // Refused without a word (busy, nothing to send to): back at once.
            if !coordinator.isBusy, coordinator.state != .thinking { chat.untuck() }
        }
        chat.model.onClose = { [weak self] in self?.closeChat() }
        coordinator.onChatOpen = { [weak self] firstMessage in
            guard let self else { return }
            overlay.endGuide()
            // Opens tucked, where the hotkey was pressed; grows out when the answer starts.
            chat.open(logoAt: invokedPoint ?? overlay.companionTriangleCenter, tucked: true)
            chat.model.addUser(firstMessage)
            chat.model.isBusy = true
        }
        coordinator.onChatUserMessage = { [weak self] message in
            self?.overlay.endGuide()
            self?.chat.model.addUser(message)
            self?.chat.model.isBusy = true
            self?.chat.tuck()  // out of the way while the answer comes; the companion pulses
        }
        confirm.onAnswer = { [weak self] yes in self?.coordinator.answerConfirmation(yes) }
        coordinator.onConfirmRequest = { [weak self] question in
            guard let self else { return }
            readyPillShown = false  // a real question replaces the offer
            coordinator.answerOffer(false)
            confirm.show(question, at: overlay.companionTopLeft)
        }
        coordinator.onConfirmEnd = { [weak self] in self?.confirm.hide() }
        // Before a walkthrough: [show me!] / [show me in Safari!] and ✕, lavender, staying
        // put. ✕, Esc or 8 s without a click: the steps are written in the chat instead.
        coordinator.onTutorialOffer = { [weak self] label in
            guard let self else { return }
            readyPillShown = false
            confirm.show("", at: overlay.companionTopLeft, confirm: label, cancel: "✕", hint: nil,
                         tone: .tutorial, waitTime: .seconds(8)) { [weak self] yes in
                self?.coordinator.answerOffer(yes)
            }
        }
        coordinator.onStepsWritten = { [weak self] text in
            guard let self, chat.isOpen else { return }
            chat.model.setAssistant(text)
            chat.model.isBusy = false
            chat.untuck()
        }
        coordinator.onReminderDayRequest = { [weak self] question, options, hint in
            guard let self else { return }
            readyPillShown = false
            coordinator.answerOffer(false)
            confirm.showChoice(question, options: options, at: overlay.companionTopLeft, hint: hint,
                               datePicker: true) { [weak self] answer in
                switch answer {
                case .option(let index): self?.coordinator.answerReminderChoice(index)
                case .date(let date): self?.coordinator.answerReminderDate(date)
                case .timedOut: self?.coordinator.answerReminderChoice(nil)
                }
            }
        }
        coordinator.onStopped = { [weak self] in
            guard let self, chat.isOpen, chat.model.isBusy else { return }
            chat.model.setAssistant(chat.model.messages.last?.role == .assistant ? (chat.model.messages.last?.text ?? "") + " …(stopped)" : "Stopped.")
            chat.model.isBusy = false
            chat.untuck()
        }
        // Replies to typed orders, notes and questions ("Added to Reminders…", a "Do it?")
        // are said by a pill or card: kept in the conversation, the chat stays aside.
        coordinator.onChatReply = { [weak self] text in
            guard let self else { return }
            chat.model.setAssistant(text)
            chat.model.isBusy = false
            chat.park()
            // Not over a green result already saying it, nor next to a card asking it.
            if !overlay.isShowingWords, !confirm.isShowing { overlay.showShortAnswer(text) }
        }
        coordinator.onChatError = { [weak self] message in
            guard let self else { return }
            chat.model.addError(message)
            chat.model.isBusy = false
            chat.park()
            overlay.show(.error(message))
        }
        coordinator.onChatClose = { [weak self] in
            self?.overlay.endGuide()
            self?.chat.close()
        }
        coordinator.onStateChange = { [weak self, weak statusBar] state in
            statusBar?.update(for: state)
            // A tap's explanation, still undoable by a second tap: not shown yet.
            if state == .thinking, self?.coordinator.isExplainProvisional == true { return }
            // Red snip thinking ends with the thinking.
            if state != .thinking { self?.overlay.setSnipAnswering(false) }
            self?.overlay.show(state)
            // Never left tucked away: once nothing is in progress (or it failed), it's back.
            if let self, chat.isTucked, !chat.isParked {
                switch state {
                case .error: chat.park()  // the error is a pill
                case .idle where !coordinator.isBusy: chat.untuck()
                default: break
                }
            }
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
            chat.untuck()  // a tutorial's checklist is the answer: show it now
        }
        coordinator.onSetupFinished = { [weak self] in self?.overlay.clearWorking() }
        coordinator.onTutorialPlanning = { [weak self] planning in self?.overlay.tutorialPlanning(planning) }
        tutorial.onFinished = { [weak self] message in
            guard let self, let message else { return }
            // A tutorial that opened another app offers the way back (ignored = stay).
            if message == TutorialController.finishedMessage, let home = coordinator.tutorialReturnApp, !home.isTerminated,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != home.processIdentifier {
                confirm.show("done! back to \(home.localizedName ?? "where you were")?", at: overlay.companionTopLeft,
                             confirm: "Back", cancel: "Stay", hint: nil, tone: .tutorial) { back in
                    if back { home.activate() }
                }
            }
            if chat.isOpen, let last = chat.model.messages.last(where: { $0.role == .assistant }) {
                chat.model.replaceLastAssistant(last.text + "\n\n" + message)
            } else if message != TutorialController.finishedMessage {
                overlay.show(.error(message))
            }
        }
        coordinator.onTour = { [weak self] parts in self?.overlay.tour(parts) }
        coordinator.onPointersRefined = { [weak self] pointers in self?.overlay.retarget(pointers) }
        coordinator.onInstantPointer = { [weak self] pointers in self?.overlay.guide(to: pointers) }
        overlay.levelSource = { [weak coordinator] in coordinator?.microphoneLevel ?? 0 }
        coordinator.onSnipMarking = { [weak self] marking in self?.overlay.setSnipping(marking) }
        coordinator.onSnipAnswering = { [weak self] on in self?.overlay.setSnipAnswering(on) }
        coordinator.onExplaining = { [weak self] selected in self?.overlay.showExplaining(selected) }
        coordinator.onPartialAnswer = { [weak self] partial in
            guard let self else { return }
            chat.model.setAssistant(partial)
            // Back once the answer is more than a pill can say (a full sentence past the pill
            // length, or a second sentence): the rest streams in view. Short replies and
            // pointing never bring it back.
            if chat.isTucked {
                var splitter = SentenceSplitter()
                let sentences = splitter.feed(partial).count
                if sentences >= 2 || (sentences >= 1 && partial.count > PillText.maxLength) { chat.untuck() }
            }
        }
        coordinator.onActionStarted = { [weak self] message in self?.overlay.showWorking(message) }
        coordinator.onActionDone = { [weak self] message in self?.overlay.showDone(message) }
        coordinator.onAnswer = { [weak self, weak statusBar] response, pointers in
            statusBar?.showAnswer(response.speech, pointers: pointers.map { "\($0.label) at \($0.quartz)" })
            guard let self else { return }
            // Pointing, or a few friendly words: the companion says it; the chat isn't needed.
            let short = PillText.fits(response.speech, code: response.code)
            let pillSays = short || !pointers.isEmpty
            if chat.isOpen {
                chat.model.setAssistant(response.displayText)  // final text, with any code as a block
                chat.model.isBusy = false
                if !pillSays {
                    chat.untuck()
                } else if chat.isTucked {
                    chat.park()  // kept in the conversation; a double tap brings it back
                }
            }
            // Already pointing (instantly, before the model): don't start over. The reply's
            // own few words label the pointer when they fit ("Share's up here!").
            if !pointers.isEmpty {
                if !coordinator.pointedInstantly { overlay.guide(to: pointers, label: short ? response.speech : nil) }
            } else if short, !(chat.isOpen && !chat.isTucked) {
                overlay.showShortAnswer(response.speech)
            }
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
