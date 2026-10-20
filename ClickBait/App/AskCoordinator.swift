import AppKit
import AVFoundation
import ClickBaitCore
import Observation

/// A pointer resolved to real screen positions.
struct ScreenPointer: Equatable {
    var label: String
    /// Global AppKit point (bottom-left origin) — for overlay windows.
    var appKit: Point
    /// Global Quartz point (top-left origin) — for Accessibility hit-testing.
    var quartz: Point
    /// A tour part's outline around the point, in screen points: the triangle's tip stops
    /// at its edge instead of on top of the thing. Nil: the tip goes to the point.
    var outline: PartOutline? = nil
}

enum AskState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case error(String)
}

/// Runs one ask from hotkey press to answer: idle → listening → thinking → speaking.
/// Answers are spoken sentence by sentence as they stream in.
@MainActor
@Observable
final class AskCoordinator {
    /// Taps shorter than this are treated as accidental and dropped silently.
    private static let minimumHold: Duration = .milliseconds(250)
    /// People let go of the keys while still saying the last word: keep listening a
    /// moment longer.
    private static let releaseTail: Duration = .milliseconds(350)
    private static let errorDisplayTime: Duration = .milliseconds(2500)

    private(set) var state: AskState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    @ObservationIgnored var onStateChange: ((AskState) -> Void)?
    /// Called with what Whisper heard.
    @ObservationIgnored var onTranscript: ((String) -> Void)?
    /// Called with the start of the highlighted text being explained (⌥⌘).
    @ObservationIgnored var onExplaining: ((String) -> Void)?
    /// A new chat bubble opens, showing the user's first message.
    @ObservationIgnored var onChatOpen: ((String) -> Void)?
    /// A follow-up was sent in the open chat (typed or spoken).
    @ObservationIgnored var onChatUserMessage: ((String) -> Void)?
    /// The model proposed a risky action: ask the user (the question to show).
    @ObservationIgnored var onConfirmRequest: ((String) -> Void)?
    /// The question is no longer pending (answered, replaced or dropped).
    @ObservationIgnored var onConfirmEnd: (() -> Void)?
    /// Set by ⌥⌘ + right-click so the following release of ⌥⌘ doesn't count as a tap.
    @ObservationIgnored private var ignoreExplainRelease = false
    /// Single ⌥⌘ tap (explain) vs double tap (type to ask).
    @ObservationIgnored private var explainTaps = DoubleTapDetector()
    /// A single tap explains at once but stays undoable until a second tap can no longer
    /// come; this ends that window (`commitExplain`).
    @ObservationIgnored private var explainCommit: Task<Void, Never>?
    /// The next typed message is a done card's clicked suggestion: it peels by itself after
    /// `PeelRule.autoPeelDelay`, like a first explanation (user's rule, 2026-10-14). Read once
    /// by `sendTyped`.
    @ObservationIgnored var nextTypedIsSuggestion = false
    /// The chat a provisional explanation detached: still on screen, put back by
    /// `undoExplain`, closed by `commitExplain`.
    @ObservationIgnored private var detachedChat: (conversation: Conversation, snipMemory: SnipMemory?)?
    /// An empty chat should open, ready to type into (⌥⌘ + right-click, double-tap ⌥⌘).
    @ObservationIgnored var onChatOpenForTyping: (() -> Void)?
    /// The open chat should take the keyboard.
    @ObservationIgnored var onChatFocus: (() -> Void)?
    /// Esc stopped an answer that was coming in (the chat stops showing it as busy).
    @ObservationIgnored var onStopped: (() -> Void)?
    /// A typed order was carried out: its confirmation, as the chat's reply.
    @ObservationIgnored var onChatReply: ((String) -> Void)?
    /// Something went wrong answering in the chat.
    @ObservationIgnored var onChatError: ((String) -> Void)?
    /// The chat closed from this side (a new ⌥⌘ explanation replaces it).
    @ObservationIgnored var onChatClose: (() -> Void)?
    /// Called with the spoken answer so far while it streams in.
    @ObservationIgnored var onPartialAnswer: ((String) -> Void)?
    /// Called when a spoken command starts running, with what it's doing.
    @ObservationIgnored var onActionStarted: ((String) -> Void)?
    /// Called after a spoken command ran, with a short confirmation.
    @ObservationIgnored var onActionDone: ((String) -> Void)?
    /// Named parts of a snipped thing to show one by one (the red tour).
    @ObservationIgnored var onTour: (([ScreenPointer]) -> Void)?
    /// A tour's names were checked against Wikipedia: its credit line, for the chat.
    @ObservationIgnored var onChatSource: ((String) -> Void)?
    /// The user started (true) or stopped marking part of the screen with ⌥⌘ held.
    @ObservationIgnored var onSnipMarking: ((Bool) -> Void)? {
        didSet { snipper.onMarkingChange = onSnipMarking }
    }
    /// A second, zoomed-in look corrected where some pointers are (same order).
    @ObservationIgnored var onPointersRefined: (([ScreenPointer]) -> Void)?
    /// Pointing before the model answers: the question names exactly one thing on screen.
    @ObservationIgnored var onInstantPointer: (([ScreenPointer]) -> Void)?
    /// The current answer already pointed instantly: its own pointers don't move the companion.
    @ObservationIgnored private(set) var pointedInstantly = false
    /// Called with the parsed answer and its pointers mapped to screen points.
    @ObservationIgnored var onAnswer: ((AssistantResponse, [ScreenPointer]) -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let speech: SpeechModelManager
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let capturer = ScreenCapturer()
    @ObservationIgnored private let snipper = SnipController()
    @ObservationIgnored private var captureTask: Task<ScreenCapture, Error>?
    @ObservationIgnored private var pressedAt: ContinuousClock.Instant?
    @ObservationIgnored private var context = ScreenContext()
    @ObservationIgnored private var frontmostPID: pid_t?
    @ObservationIgnored private var frontmostBundleID: String?
    @ObservationIgnored private var snapshotTask: Task<AXSnapshot, Never>?
    @ObservationIgnored private var provider: (any LLMProvider)?
    @ObservationIgnored private var errorResetTask: Task<Void, Never>?
    @ObservationIgnored private var askTask: Task<Void, Never>?
    @ObservationIgnored var backgroundJobs: BackgroundJobs?
    @ObservationIgnored private var activeAnswerRun: AnswerRun?
    /// The spoken question or snip in progress (nil when none): how far it has got and what it
    /// is known to be, which decides what ⌃⌥ does (`PeelRule`). A question sent to the
    /// background keeps its own flow; this one is then nil or the next question's.
    @ObservationIgnored private var currentFlow: QuestionFlow?
    /// A queued peel turned out to be quick (a command, a walkthrough, an instant pick), or ⌃⌥
    /// came for something already known to be, or a returning snip's area has moved: the
    /// short pill, in the job's colour. `true` shows it at once; `false` waits until nothing
    /// else is being said.
    @ObservationIgnored var onQuickEnding: ((String, CompanionTone, Bool) -> Void)?
    @ObservationIgnored var onPeel: ((BackgroundJob) -> [ChatModel.Message])?
    @ObservationIgnored var onPeelRefused: (() -> Void)?
    /// The open chat bubble's memory. Nil when no bubble is open; dropped on close.
    @ObservationIgnored private(set) var conversation: Conversation?
    /// A reply is being fetched for the chat (blocks a second send).
    @ObservationIgnored private(set) var isAnswering = false
    /// The current answer flow owns shared busy state until a newer flow replaces it.
    @ObservationIgnored private var answerFlowID: UUID?
    @ObservationIgnored private var answeringOwnerID: UUID?
    @ObservationIgnored let speaker: Speaker
    /// When the user let go (or pressed ⌥⌘), for the time-to-first-audio log.
    @ObservationIgnored private var answerStartedAt: ContinuousClock.Instant?

    init(settings: AppSettings, speech: SpeechModelManager) {
        self.settings = settings
        self.speech = speech
        speaker = Speaker(settings: settings)
        recorder.prepare()
        speaker.onStart = { [weak self] in
            guard let self, let started = answerStartedAt else { return }
            answerStartedAt = nil  // log once per answer; Preview in Settings isn't an answer
            Log.ask.notice("First audio \(String(describing: ContinuousClock.now - started), privacy: .public) after release")
        }
    }


    func handle(_ event: ChordDetector.Event) {
        switch event {
        case .askPressed: begin()
        case .askReleased:
            // Only the press that started listening has a question to finish; an ignored press
            // must not replace the task of the one being answered.
            guard state == .listening, let flow = currentFlow, flow.phase == .listening, !flow.released else { break }
            flow.released = true
            askTask = Task { await finish() }
        case .askCancelled: cancel(reason: "another key was pressed")
        case .explainPressed:
            // Busy answering: a tap still explains, but nothing to snip into.
            if state != .listening, state != .thinking, !isAnswering { snipper.begin() }
        case .explainReleased:
            // Letting go of ⌥⌘ after a right-click (type to ask) isn't a tap.
            if ignoreExplainRelease {
                ignoreExplainRelease = false
                explainTaps.reset()
                snipper.cancel()
                return
            }
            let armed = snipper.isArmed
            switch snipper.isActive ? snipper.end() : .tap {
            case .snip(let kind, let region, let path):
                explainTaps.reset()
                snip(kind, region: region, path: path)
            case .tap where armed:
                explainTaps.reset()
                Log.ask.notice("Snip armed but nothing marked; ignoring")
            case .tap:
                explainTapped()
            }
        case .explainCancelled:
            snipper.cancel()
            explainTaps.reset()
            ignoreExplainRelease = false
        }
    }

    /// Tap ⌥⌘: explain the highlighted text. Double-tap ⌥⌘: open a chat to type into,
    /// the keyboard-only twin of ⌥⌘ + right-click (no selection needed).
    private func explainTapped() {
        switch explainTaps.tap(at: ProcessInfo.processInfo.systemUptime) {
        case .first:
            onInvoked?()
            // Explain now (no waiting), but keep it undoable for the double-tap window. The
            // window opens first, so nothing of the explanation shows during it.
            explainCommit?.cancel()
            explainCommit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(DoubleTapDetector.defaultWindow))
                guard !Task.isCancelled else { return }
                self?.commitExplain()
            }
            explain()
        case .second:
            undoExplain()
            startTypedChat(trigger: "double-tap ⌥⌘")
        }
    }

    /// The double-tap window passed: the tap really was a single one.
    /// Inside the double-tap window: the explanation is working but not shown yet (a double
    /// tap must leave the companion blue and still, not flash orange and spin).
    var isExplainProvisional: Bool { explainCommit != nil }
    /// The selection read during the window, shown once it's committed.
    @ObservationIgnored private var pendingExcerpt: String?
    /// The chat the explanation started during the window (its first line), opened at commit.
    @ObservationIgnored private var explainChat: String?

    private func commitExplain() {
        explainCommit = nil
        // Now show what was held back: the thinking state, and the excerpt if it's in.
        onStateChange?(state)
        if let excerpt = pendingExcerpt {
            pendingExcerpt = nil
            onExplaining?(excerpt)
        }
        // The old chat goes first: closing it after opening the explanation's chat closed
        // the new one instead (same window), so the explanation never appeared.
        if detachedChat != nil {
            detachedChat = nil
            onChatClose?()
        }
        if let display = explainChat {
            explainChat = nil
            onChatOpen?(display)
        }
    }

    /// A second tap (or Esc) inside the window: drop the explanation quietly and put back
    /// the chat it had detached, as if the first tap never happened.
    private func undoExplain() {
        explainCommit?.cancel()
        explainCommit = nil
        pendingExcerpt = nil
        if explainChat != nil {
            // The explanation had started its own chat: gone with it.
            explainChat = nil
            conversation = nil
            snipMemory = nil
            chatShown = false
        }
        if state == .thinking || isAnswering {
            askTask?.cancel()
            askTask = nil
            invalidateAnswerFlow()
            state = .idle
            Log.ask.notice("Explain undone (second tap)")
        }
        if let detached = detachedChat {
            conversation = detached.conversation
            snipMemory = detached.snipMemory
            chatShown = true
            detachedChat = nil
        }
    }

    /// The overlay dismissed the answer (click, Escape or timeout). If it was still
    /// streaming in, stop the request too so it doesn't pop back up.
    func answerDismissed() {
        speaker.stop()
        askTask?.cancel()
        askTask = nil
        invalidateAnswerFlow()
        if state == .speaking || state == .thinking { state = .idle }
    }

    // MARK: - Chat

    /// The chat bubble was closed (✕ or Escape): its memory goes with it.
    func detachChatForCapsule() -> (conversation: Conversation, snipMemory: SnipMemory?)? {
        guard chatShown, let conversation else { return nil }
        let detached = (conversation: conversation, snipMemory: snipMemory)
        self.conversation = nil
        chatShown = false
        snipMemory = nil
        return detached
    }

    func restoreBackgroundConversation(_ restored: Conversation, snipMemory: SnipMemory? = nil) {
        conversation = restored
        chatShown = true
        var snipMemory = snipMemory
        snipMemory?.returnedFromBackground = true
        self.snipMemory = snipMemory
    }

    /// "show me the parts" on a done card whose tour was placed in the dock: tour it now, if
    /// the snipped area still looks the same. False when there is no such tour (then the
    /// suggestion is asked as usual).
    func playReadyTour() -> Bool {
        guard var memory = snipMemory, let tour = memory.readyTour, let view = memory.view else { return false }
        memory.readyTour = nil
        snipMemory = memory
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await stillShows(view) {
                Log.ask.notice("Parts: tour of \(tour.count, privacy: .public) stop(s) placed in the dock")
                onTour?(tour)
            } else {
                Log.ask.notice("Parts: the snipped area has changed since it was sent away; no tour")
                onQuickEnding?(PeelRule.movedPill, .capture, true)
            }
        }
        return true
    }

    func closeChat() {
        tutorial?.stop(message: nil)
        guard conversation != nil, chatShown else { return }
        speaker.stop()
        askTask?.cancel()
        askTask = nil
        conversation = nil
        chatShown = false
        currentFlow?.pendingSnipView?.text.cancel()
        currentFlow?.pendingSnipView?.objects.cancel()
        snipMemory?.text?.cancel()
        snipMemory?.objects?.cancel()
        snipMemory?.reference?.cancel()
        currentFlow?.pendingSnipView = nil
        snipMemory = nil
        invalidateAnswerFlow()
        if state == .thinking || state == .speaking { state = .idle }
        Log.ask.notice("Chat closed")
    }

    /// A message typed into the open chat bubble. Replies to typed messages are text only.
    func sendTyped(_ text: String) {
        let autoPeels = nextTypedIsSuggestion
        nextTypedIsSuggestion = false
        stopRefining()
        tutorial?.stop(message: nil)
        guard conversation != nil, !isAnswering, state != .listening else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if settings.blocklist.isBlocked(bundleID: frontmost?.bundleIdentifier) {
            onChatError?("ClickBait doesn't look at \(frontmost?.localizedName ?? "this app") — it's on your blocklist.")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            onChatError?("Screen Recording is off. Open Permissions… from the menu bar icon.")
            return
        }
        let pid = frontmost?.processIdentifier
        frontmostPID = pid
        frontmostBundleID = frontmost?.bundleIdentifier
        context = ScreenContext(appName: frontmost?.localizedName)

        answerStartedAt = .now  // for the timing logs: from this message, not the last spoken one
        if NoteReference.asksToSeeNote(text), ActionExecutor.lastNoteID.withLock({ $0 }) != nil {
            onChatUserMessage?(text)
            Task { if let reply = await showLastNote(speak: false) { onChatReply?(reply) } }
            return
        }
        // A typed day answers a reminder's "when?" in the chat.
        if pendingReminder != nil {
            if let day = ReminderDay.parse(text) {
                onChatUserMessage?(text)
                let answerID = beginAnswerFlow()
                askTask = Task {
                    defer { finishAnswering(answerID) }
                    await resolveReminder(day)
                }
                return
            }
            dropPendingReminder()
        }
        // Typed orders run like spoken ones ("combine these files"), answered in the chat.
        if settings.commandsEnabled,
           let command = CommandParser.parse(text, allowedShortcuts: settings.allowedShortcuts),
           !isUnknownApp(command) {
            Log.ask.notice("Command recognised (typed): \(command.name, privacy: .public)")
            onChatUserMessage?(text)
            let answerID = beginAnswerFlow()
            askTask = Task {
                defer { finishAnswering(answerID) }
                if let action = asksFirst(command) {
                    onChatReply?(await handleOrder(action, request: command, speak: false, from: .clearOrder))
                    return
                }
                switch await perform(command, speak: false) {
                case .success(let confirmation): onChatReply?(confirmation + ".")
                case .failure(let message): onChatError?(message)
                case .asked(let question): onChatReply?(question)
                }
            }
            return
        }

        let provider = settings.makeProvider()
        self.provider = provider
        let blocklist = settings.blocklist
        // Orange and spinning while a typed message is worked on, like a spoken one (it
        // stayed idle blue); back to idle if it ends without an answer taking over.
        state = .thinking
        askTask = Task {
            defer { if state == .thinking { state = .idle } }
            let startedAt = ContinuousClock.now
            if let (order, proposal) = await understandOrder(text) {
                onChatUserMessage?(text)
                let answerID = beginAnswerFlow()
                defer { finishAnswering(answerID) }
                switch order {
                case .ready(let action): onChatReply?(await handleOrder(action, request: proposal, speak: false, from: .modelGuess))
                case .failed(let reason): onChatError?(reason)
                }
                return
            }
            let snapshot = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid) }.value
            context.windowTitle = snapshot.windowTitle
            context.windowFrame = snapshot.windowFrame
            context.focusedElement = snapshot.focusedElement
            let capture: ScreenCapture
            do {
                capture = try await capturer.captureDisplayUnderCursor(excluding: blocklist, ignoreClickBait: settings.ignoreNotchInCaptures)
            } catch {
                onChatError?("Couldn't capture the screen: \(error.localizedDescription)")
                return
            }
            let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(capture.image) }
            let elements = await Self.elements(in: capture, frontmostPID: pid)
            if await startTutorial(question: text, capture: capture, encoding: encoding, elements: elements,
                                   speak: false, display: text) { return }
            await respond(question: text, selectedText: nil, capture: capture, encoding: encoding, startedAt: startedAt,
                          speak: false, display: text, elements: elements, autoPeels: autoPeels)
        }
    }

    /// Escape while listening or thinking abandons the question.
    /// ⌥⌘ + right-click or double-tap ⌥⌘: an empty chat to type the first question into. Sent messages go
    /// through `sendTyped` like any typed follow-up (screen, pointing, actions).
    func startTypedChat(trigger: String = "⌥⌘ right-click") {
        onInvoked?()
        if snipper.isActive { snipper.cancel() }
        let flags = NSEvent.modifierFlags
        if flags.contains(.option), flags.contains(.command) { ignoreExplainRelease = true }
        if conversation != nil, chatShown {
            onChatFocus?()  // already open: just type into it
            return
        }
        stopActivity()
        conversation = Conversation()
        snipMemory = nil
        chatShown = true
        Log.ask.notice("Chat opened for typing (\(trigger, privacy: .public))")
        onChatOpenForTyping?()
    }

    /// Something is going on that Esc should stop (Esc is then taken from other apps).
    var isBusy: Bool {
        state == .listening || state == .thinking || state == .speaking || isAnswering || speaker.isSpeaking
            || snipper.isActive || pendingAction != nil || pendingReminder != nil || isRefining || (tutorial?.isActive ?? false)
    }

    /// Esc belongs to ClickBait: anything `isBusy` counts, plus a walkthrough offer waiting
    /// for its answer, an explanation still undoable, and an app opening for a walkthrough.
    var ownsEscape: Bool {
        isBusy || pendingOffer != nil || explainCommit != nil || isOpeningAppForTutorial
    }

    /// Esc: stop whatever ClickBait is doing — listening, thinking, speaking, a snip,
    /// a pending "Do it?", a background second look. Returns false if nothing was
    /// going on (Esc then closes the chat instead).
    @discardableResult
    func stopActivity() -> Bool {
        var stopped: [String] = []
        if snipper.isActive { snipper.cancel(); stopped.append("snip") }
        if explainCommit != nil {
            undoExplain()
            stopped.append("explain")
        }
        if pendingAction != nil { dropPending(); stopped.append("confirmation") }
        if pendingReminder != nil { dropPendingReminder(); stopped.append("reminder") }
        if pendingOffer != nil { answerOffer(false); onConfirmEnd?(); stopped.append("walkthrough offer") }
        onSnipAnswering?(false)
        if isRefining { stopRefining(); stopped.append("close-up") }
        if tutorial?.isActive == true { tutorial?.stop(message: "Tutorial stopped."); stopped.append("tutorial") }
        if state == .listening || state == .thinking || isAnswering {
            cancelInFlight()
            onStopped?()
            stopped.append("answer")
        }
        if speaker.isSpeaking || state == .speaking {
            speaker.stop()
            if state == .speaking { state = .idle }
            stopped.append("speech")
        }
        if !stopped.isEmpty { Log.ask.notice("Esc stopped: \(stopped.joined(separator: ", "), privacy: .public)") }
        return !stopped.isEmpty
    }

    func cancelInFlight() {
        speaker.stop()
        if isAnswering {
            askTask?.cancel()
            askTask = nil
            invalidateAnswerFlow()
        }
        switch state {
        case .listening:
            cancel(reason: "Escape pressed")
        case .thinking:
            askTask?.cancel()
            askTask = nil
            captureTask?.cancel()
            captureTask = nil
            state = .idle
            Log.ask.notice("Cancelled while thinking: Escape pressed")
        default:
            break
        }
    }

    private func begin() {
        guard !isCardRecording else {
            Log.ask.notice("⌃⌥ ignored: a card's voice panel is recording")
            return
        }
        guard acceptsNewQuestion() else { return }
        stopRefining()
        tutorial?.stop(message: nil)  // a new question ends a tutorial
        guard state != .listening, state != .thinking, !isAnswering else {
            Log.ask.notice("⌃⌥ ignored: busy")
            return
        }
        speaker.stop()  // never record ClickBait talking
        errorResetTask?.cancel()

        let frontmost = NSWorkspace.shared.frontmostApplication
        guard checkCanAsk(frontmost: frontmost) else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            show(error: "Microphone access is off. Open Permissions… from the menu bar icon.")
            return
        }
        // Check before recording so nobody talks into a pipeline that can't hear them.
        switch speech.state {
        case .ready:
            break
        case .notDownloaded, .downloading, .importing:
            show(error: "The speech model isn't downloaded yet. Open Settings… → Speech.")
            return
        case .loading:
            show(error: "The speech model is still loading. Try again in a moment.")
            return
        case .failed(let message):
            show(error: message)
            return
        }
        let micStart = ContinuousClock.now
        do {
            try recorder.start()
        } catch {
            Log.input.error("Recorder failed to start: \(error.localizedDescription, privacy: .public)")
            show(error: "Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        pressedAt = .now
        onInvoked?()
        Log.input.notice("Microphone started in \(String(describing: ContinuousClock.now - micStart), privacy: .public)")
        // Capture at press time: the screen the user is asking about is the one they
        // were looking at when they started talking.
        let blocklist = settings.blocklist
        captureTask = Task { [capturer, ignoreClickBait = settings.ignoreNotchInCaptures] in
            try await capturer.captureDisplayUnderCursor(excluding: blocklist, ignoreClickBait: ignoreClickBait)
        }
        context = ScreenContext(appName: frontmost?.localizedName)
        let pid = frontmost?.processIdentifier
        frontmostPID = pid
        frontmostBundleID = frontmost?.bundleIdentifier
        snapshotTask = Task.detached(priority: .userInitiated) {
            // Chrome and Electron apps only build their accessibility tree when asked;
            // asking now gives them the time the user spends talking to do it.
            AXInspector.requestAccessibilityTree(pid: pid)
            return AXInspector.snapshot(frontmostPID: pid)
        }
        // Load a cold local model while the user is still talking. Sends no user content.
        let provider = settings.makeProvider()
        self.provider = provider
        Task.detached(priority: .userInitiated) { await provider.warmUp() }
        let flow = QuestionFlow(work: .answer, phase: .listening)
        flow.provider = provider
        flow.context = context
        flow.homeBundleID = frontmost?.bundleIdentifier
        flow.homePID = pid
        currentFlow = flow
        state = .listening
        Log.ask.notice("Listening (frontmost: \(frontmost?.bundleIdentifier ?? "none", privacy: .private))")
    }

    /// In Chrome or Safari: asks the browser which tab is showing in the window at `point`
    /// (Quartz; its front window when nil), matched to the title accessibility saw there.
    /// The first time, macOS asks to let ClickBait control the browser.
    private func readBrowserTab(for flow: QuestionFlow, at point: Point?) {
        guard let browser = BrowserTab.browser(for: flow.homeBundleID) else { return }
        let title = flow.context.windowTitle
        let pid = flow.homePID
        flow.browserTab = Task {
            let tabs: [BrowserTab]
            switch browser {
            case .chrome:
                guard let pid else { return nil }
                tabs = await Task.detached(priority: .userInitiated) { ChromeTabs.read(pid: pid, at: point) }.value
            case .safari:
                let output = try? await AppleScriptRunner.run(BrowserTab.safariCaptureScript(at: point), app: browser.name)
                tabs = BrowserTab.parse(output ?? "", browser: browser)
            }
            let tab = BrowserTab.pick(tabs, title: title)
            Log.ask.notice("Home tab: \(tab == nil ? "not found" : "read from \(browser.name)", privacy: .public)")
            return tab
        }
    }

    // MARK: - Follow-ups from a done card (its mini-chat, `FollowUpPanel`)

    /// The microphone is on for a card's voice panel (not ⌃⌥ listening).
    @ObservationIgnored private(set) var isCardRecording = false
    /// Its loudness, for the card's waveform.
    var cardMicrophoneLevel: Float { isCardRecording ? recorder.level : 0 }

    /// Starts the microphone for a card's voice panel. Nil, or why it can't.
    func startCardRecording() -> String? {
        guard !isCardRecording else { return nil }
        guard state == .idle, currentFlow == nil, !isAnswering else {
            return "ClickBait is busy with a question. Try again in a moment."
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return "Microphone access is off. Open Permissions… from the menu bar icon."
        }
        switch speech.state {
        case .ready: break
        case .notDownloaded, .downloading, .importing: return "The speech model isn't downloaded yet. Open Settings… → Speech."
        case .loading: return "The speech model is still loading. Try again in a moment."
        case .failed(let message): return message
        }
        speaker.stop()  // never record ClickBait talking
        do {
            try recorder.start()
        } catch {
            Log.input.error("Card voice: recorder failed to start: \(error.localizedDescription, privacy: .public)")
            return "Couldn't start the microphone: \(error.localizedDescription)"
        }
        isCardRecording = true
        Log.ask.notice("Card voice: recording")
        return nil
    }

    /// The card's voice panel folded or switched mid-recording: the recording is dropped.
    func cancelCardRecording() {
        guard isCardRecording else { return }
        _ = recorder.stop()
        isCardRecording = false
        Log.ask.notice("Card voice: recording dropped")
    }

    /// Stop: the words heard ("" when nothing was), or why not.
    func finishCardRecording() async -> Result<String, CardVoiceError> {
        guard isCardRecording else { return .failure(CardVoiceError(message: "The recording had already stopped.")) }
        let samples = recorder.stop()
        isCardRecording = false
        let audio = AudioConditioner.condition(samples, sampleRate: AudioRecorder.sampleRate)
        guard !audio.isSilent else {
            Log.ask.notice("Card voice: silent")
            return .success("")
        }
        do {
            let text = try await speech.transcribe(audio.samples)
            Log.ask.notice("Card voice: \(text.count, privacy: .public) characters heard")
            return .success(text)
        } catch {
            Log.ask.error("Card voice: transcription failed: \(error.localizedDescription, privacy: .public)")
            return .failure(CardVoiceError(message: "Couldn't understand the recording: \(error.localizedDescription)"))
        }
    }

    struct CardVoiceError: Error {
        let message: String
    }

    /// A follow-up typed or spoken into a done card's mini-chat: asked in the dock, the tile
    /// working again (`BackgroundJobs.reopen`); the foreground is left alone. It runs as a
    /// queued peel does (`respond` with the job's flow): the job's conversation and snip
    /// memory, a text-only answer, no pointing or tour. Nil, or why it can't.
    func askInBackground(_ text: String, jobID: UUID) -> String? {
        guard let backgroundJobs, let entry = backgroundJobs.entries.first(where: { $0.id == jobID }),
              case .done = entry.job.status else { return "That one isn't waiting for a follow-up any more." }
        guard CGPreflightScreenCaptureAccess() else { return "Screen Recording is off. Open Permissions… from the menu bar icon." }
        let job = entry.job
        let flow = QuestionFlow(work: entry.snipMemory != nil ? .snip : .answer, phase: .buildingRequest)
        flow.provider = settings.makeProvider()
        let home = job.homePID.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
        flow.context = ScreenContext(appName: home?.localizedName, windowTitle: job.homeWindowTitle)
        flow.context.windowFrame = job.homeWindowFrame
        flow.homeBundleID = job.homeBundleID
        flow.homePID = job.homePID
        flow.jobID = jobID
        flow.sentAway = true
        flow.conversation = job.conversation
        flow.snipMemory = entry.snipMemory
        flow.chatMessages = entry.chatMessages
        let blocklist = settings.blocklist
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = ContinuousClock.now
            let capture: ScreenCapture
            do {
                capture = try await capturer.captureDisplayUnderCursor(excluding: blocklist, ignoreClickBait: settings.ignoreNotchInCaptures)
            } catch {
                report("Couldn't capture the screen: \(error.localizedDescription)", for: flow)
                return
            }
            let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(capture.image) }
            await respond(question: text, selectedText: nil, capture: capture, encoding: encoding, startedAt: startedAt,
                          speak: false, display: text, flow: flow)
        }
        flow.task = task
        backgroundJobs.reopen(jobID, asking: text, task: task)
        Log.ask.notice("Card follow-up asked in the dock: \(jobID.uuidString, privacy: .public)")
        return nil
    }

    // MARK: - Sending a question to the background (⌃⌥ while it is orange)

    /// Where the question in progress has got, as `PeelRule` sees it. A flow whose end was
    /// missed (the state moved on without it) counts as idle rather than blocking ⌃⌥.
    private var currentPhase: PeelRule.Phase {
        guard let flow = currentFlow else { return .idle }
        if flow.phase == .listening, state != .listening { return .idle }
        if flow.phase.isPreRun, state != .thinking { return .idle }
        return flow.phase
    }

    /// Stops the recording and starts thinking (orange): at the end of the release tail, or
    /// early when ⌃⌥ is pressed during it. The capture and snapshot tasks move to the flow, so
    /// the next question can start its own. The recorder stops before that question's starts.
    private func endTail(_ flow: QuestionFlow, releasedAt: ContinuousClock.Instant) {
        flow.samples = recorder.stop()
        answerStartedAt = releasedAt
        state = .thinking
        flow.phase = .transcribing
        pressedAt = nil
        flow.captureTask = captureTask
        flow.snapshotTask = snapshotTask
        captureTask = nil
        snapshotTask = nil
    }

    /// ⌃⌥ pressed: peel the question in progress (now, or as soon as its run exists), or say
    /// why not. True when the press goes on to become the next question.
    private func acceptsNewQuestion() -> Bool {
        let flow = currentFlow
        // Let go a moment ago and still in the tail: the companion is orange, so this press
        // ends the tail now and counts as a press during transcribing.
        if let flow, currentPhase == .listening, flow.released, let held = pressedAt.map({ ContinuousClock.now - $0 }),
           held >= Self.minimumHold {
            endTail(flow, releasedAt: .now)
        }
        let situation = PeelRule.Situation(phase: currentPhase, work: flow?.work ?? .answer,
                                           kind: flow?.kind ?? .unknown, hasRoom: backgroundJobs?.hasRoom ?? false)
        switch PeelRule.outcome(of: .chord, in: situation) {
        case .startNew:
            return true
        case .peelNow:
            guard let flow else { return true }
            if let run = flow.run { return peel(flow, run, situation) }
            return queuePeel(flow)
        case .peelWhenReady:
            guard let flow else { return true }
            return queuePeel(flow)
        case .tooQuick:
            // Nothing to send away: the question finishes in the foreground, and this press
            // doesn't become a new one (the answer is moments away, and the companion is busy).
            Log.ask.notice("⌃⌥ ignored: that one is quick, nothing to send away")
            onQuickEnding?(PeelRule.quickPill, flow?.work == .snip ? .capture : .processing, false)
            return false
        case .ignore(let reason):
            if reason == .threesACrowd { onPeelRefused?() }
            Log.ask.notice("⌃⌥ ignored: \(reason.logText, privacy: .public)")
            return false
        }
    }

    /// Makes the job's tile now (with the peel animation) and clears the foreground, so the
    /// next question starts with fresh state and nothing of this one's.
    private func startPeel(_ flow: QuestionFlow) -> BackgroundJob? {
        guard let backgroundJobs else { return nil }
        let run = flow.run
        let snipChat = flow.work == .snip || (conversation?.isEmpty == false && snipMemory != nil)
        let job = BackgroundJob(question: run?.question ?? flow.heard ?? (flow.work == .snip ? "" : "your question"),
                                kind: run?.kind ?? (snipChat ? .snip : .answer),
                                homeBundleID: flow.homeBundleID, homePID: flow.homePID,
                                conversation: run?.conversation ?? conversation ?? Conversation())
        let task = run?.task ?? askTask
        guard backgroundJobs.add(job, task: task) else {
            onPeelRefused?()
            return nil
        }
        flow.task = task
        flow.jobID = job.id
        flow.sentAway = true
        flow.conversation = conversation
        flow.snipMemory = snipMemory
        flow.chatMessages = onPeel?(job) ?? []
        // The task belongs to the tile now (its ✕ stops it): Esc, dismissing an answer or
        // closing a chat cancels `askTask`, which would silently kill the background answer.
        if askTask == task { askTask = nil }
        if let run {
            if answerFlowID == run.id { answerFlowID = nil }
            finishAnswering(run.id)
            finishRefining(run.id)
            if activeAnswerRun === run { activeAnswerRun = nil }
        }
        speaker.stop()
        onSnipAnswering?(false)
        conversation = nil
        snipMemory = nil
        chatShown = false
        if currentFlow === flow { currentFlow = nil }
        state = .idle
        return job
    }

    /// The run joins its tile: its words, result and errors go to the job from here on.
    private func attach(_ run: AnswerRun, to flow: QuestionFlow, appendingQuestion: Bool) {
        guard let jobID = flow.jobID, let backgroundJobs else { return }
        run.destination = .background(jobID)
        run.task = flow.task
        var messages = flow.chatMessages
        if messages.isEmpty || appendingQuestion { messages.append(ChatModel.Message(role: .user, text: run.display)) }
        run.chatMessages = messages
        backgroundJobs.setSnipMemory(run.snipMemory, for: jobID)
        backgroundJobs.setChatMessages(messages, for: jobID)
        // The window it was asked in, for "go there!" (its context is complete by now), and
        // in a browser its exact tab.
        backgroundJobs.setHomeWindow(title: flow.context.windowTitle, frame: flow.context.windowFrame, for: jobID)
        if flow.browserTab == nil { readBrowserTab(for: flow, at: nil) }
        if let reading = flow.browserTab {
            Task { @MainActor [weak self] in self?.backgroundJobs?.setHomeTab(await reading.value, for: jobID) }
        }
        flow.joined = true
    }

    /// The answer is streaming: peel it. A snip whose explanation is already complete keeps
    /// it in the done card and skips its tour, offering "show me the parts" instead.
    private func peel(_ flow: QuestionFlow, _ run: AnswerRun, _ situation: PeelRule.Situation) -> Bool {
        guard case .foreground = run.destination else {
            Log.ask.notice("Peel skipped: the answer is already in the background")
            return false
        }
        guard let job = startPeel(flow) else {
            Log.ask.notice("Peel skipped: no free slot or no job list")
            return false
        }
        attach(run, to: flow, appendingQuestion: false)
        Log.ask.notice("Peeled answer \(job.id.uuidString, privacy: .public) into a background capsule")
        if run.explanation != nil {
            let parts = PeelRule.skipsTourAndSuggestsParts(situation) && run.expectsTour != false
            keepExplanation(of: run, jobID: job.id, suggestParts: parts)
        }
        return true
    }

    /// The run doesn't exist yet (transcribing, order check, element pick) or hasn't started
    /// streaming: the tile is made now; the question carries on and its run joins the tile
    /// when the model request starts (`respond`), or it ends as a command or an instant pick
    /// (`settleQuick`).
    private func queuePeel(_ flow: QuestionFlow) -> Bool {
        guard startPeel(flow) != nil else { return false }
        Log.ask.notice("Peel queued: waiting for the answer to start")
        return true
    }

    /// `PeelRule.autoPeelDelay` after the explanation's model request starts: if it is still
    /// working in front, peel it as ⌃⌥ would. Not before a second ⌥⌘ tap is ruled out (a
    /// double tap drops the explanation instead).
    private func scheduleAutoPeel(_ flow: QuestionFlow, _ run: AnswerRun) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: PeelRule.autoPeelDelay)
            await self?.explainCommit?.value
            self?.autoPeel(flow, run)
        }
    }

    private func autoPeel(_ flow: QuestionFlow, _ run: AnswerRun) {
        guard flow.run === run, activeAnswerRun === run, case .foreground = run.destination,
              run.task?.isCancelled != true else { return }
        let situation = PeelRule.Situation(phase: flow.phase, work: flow.work, kind: flow.kind,
                                           hasRoom: backgroundJobs?.hasRoom ?? false)
        // Complete when the 0.5 s came: a fast answer keeps the companion it has.
        guard PeelRule.autoPeels(situation, answeredAlready: run.explanation != nil) else {
            if run.explanation != nil { Log.ask.notice("Auto-peel skipped: answered within \(String(describing: PeelRule.autoPeelDelay), privacy: .public)") }
            if !situation.hasRoom, flow.phase.hasRun { Log.ask.notice("Auto-peel skipped: three's a crowd, finishing in front") }
            return
        }
        if peel(flow, run, situation) {
            Log.ask.notice("Auto-peeled after \(String(describing: PeelRule.autoPeelDelay), privacy: .public) (\(flow.work == .snip ? "snip" : "explanation", privacy: .public))")
        }
    }

    /// Whether the snipped area still looks as it did: captured again and compared with
    /// the close-up (`SnipMatch`, on this Mac, no model).
    private func stillShows(_ view: SnipView) async -> Bool {
        let center = NSPoint(x: view.crop.midX, y: view.primaryDisplayHeight - view.crop.midY)
        guard let capture = try? await capturer.captureDisplayUnderCursor(excluding: settings.blocklist, at: center,
                                                                          ignoreClickBait: settings.ignoreNotchInCaptures),
              let fresh = try? SnipRenderer.view(capture, region: view.markedOnScreen),
              fresh.crop == view.crop else { return false }
        let difference = SnipMatch.difference(view.thumbnail, fresh.thumbnail)
        Log.ask.notice("Parts: snipped area differs by \(difference.map { String(format: "%.1f", $0) } ?? "?", privacy: .public) grey levels")
        return SnipMatch.matches(view.thumbnail, fresh.thumbnail)
    }

    /// A flow for work that doesn't start from a spoken question or a snip (⌥⌘ explain, typed
    /// follow-ups), made when its answer starts so a streaming answer can still be peeled.
    private func adHocFlow(snip: Bool) -> QuestionFlow {
        let flow = QuestionFlow(work: snip ? .snip : .answer, phase: .buildingRequest)
        flow.provider = provider
        flow.context = context
        flow.homeBundleID = frontmostBundleID
        flow.homePID = frontmostPID
        flow.task = askTask
        if currentFlow == nil { currentFlow = flow }
        return flow
    }

    private func keepExplanation(of run: AnswerRun, jobID: UUID, suggestParts: Bool) {
        guard let text = run.explanation, let backgroundJobs else { return }
        run.recordTurn?(&run.conversation)
        run.recordTurn = nil
        settleChat(of: run, finalText: text)
        backgroundJobs.setChatMessages(run.chatMessages, for: jobID)
        backgroundJobs.complete(jobID, answer: text, conversation: run.conversation)
        if suggestParts { backgroundJobs.setLeadingSuggestion(PeelRule.suggestedPartsPrompt, for: jobID) }
        run.task?.cancel()  // the tour: marks, placement and pointing never run
        Log.ask.notice("Peel kept the explanation and skipped the tour: \(jobID.uuidString, privacy: .public)")
    }

    /// The answer's text goes into the run's chat messages: the last assistant message after
    /// the last question, or a new one.
    private func settleChat(of run: AnswerRun, finalText: String) {
        let lastUser = run.chatMessages.lastIndex(where: { $0.role == ChatModel.Message.Role.user })
        let lastAssistant = run.chatMessages.lastIndex(where: { $0.role == ChatModel.Message.Role.assistant })
        if let lastUser, let lastAssistant, lastAssistant > lastUser {
            run.chatMessages[lastAssistant].text = finalText
        } else {
            run.chatMessages.append(ChatModel.Message(role: .assistant, text: finalText))
        }
    }

    /// A queued question turned out to need no model answer (`flow.kind` says which): per
    /// `PeelRule.resolution` its tile goes. A command or walkthrough then runs as usual and an
    /// instant pick points, as soon as the foreground is free (the next question may be
    /// listening): at once if it is, else after waiting at most 10 s. Past that, or for a pick
    /// whose capture is over 15 s old, it is dropped with a visible pill. The "quick" pill
    /// shows only once the work actually starts. `resolvesPending`: this is the "yes" or the
    /// day that answers a waiting question, which must not count as the foreground being busy.
    private func settleQuick(_ flow: QuestionFlow, resolvesPending: Bool = false) async -> Bool {
        guard let id = flow.jobID, !flow.joined else { return true }
        let isPick = flow.kind == .instantPick
        let tone: CompanionTone = flow.work == .snip ? .capture : .processing
        let busy = isBusy || currentFlow != nil
        let resolution = PeelRule.resolution(of: isPick ? .instantPick(foregroundBusy: busy) : .command)
        backgroundJobs?.remove(id)
        flow.jobID = nil
        Log.ask.notice("""
            Peel ended quick (\(isPick ? "instant pick" : "command", privacy: .public)): \
            \(id.uuidString, privacy: .public) \(String(describing: resolution), privacy: .public)
            """)
        let stale = isPick && ContinuousClock.now - flow.startedAt > .seconds(15)
        var free = !stale
        if free { free = await waitForForeground(upTo: .seconds(10), resolvingPending: resolvesPending) }
        guard free else {
            Log.ask.notice("Queued \(isPick ? "pick" : "command", privacy: .public) dropped: \(stale ? "its screen is too old" : "the foreground stayed busy", privacy: .public)")
            onQuickEnding?(Self.droppedPill, tone, false)
            return false
        }
        currentFlow = flow
        askTask = flow.task
        provider = flow.provider
        context = flow.context
        frontmostPID = flow.homePID
        frontmostBundleID = flow.homeBundleID
        state = .thinking
        if let pill = resolution.pill { onQuickEnding?(pill, tone, false) }
        return true
    }

    static let droppedPill = "couldn't do that while you were busy — ask again"

    private func foregroundIsFree(resolvingPending: Bool) -> Bool {
        guard currentFlow == nil, state == .idle, !isAnswering, !isRefining, !speaker.isSpeaking,
              !snipper.isActive else { return false }
        return resolvingPending || (pendingAction == nil && pendingReminder == nil && !(tutorial?.isActive ?? false))
    }

    private func waitForForeground(upTo limit: Duration, resolvingPending: Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !foregroundIsFree(resolvingPending: resolvingPending) {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !Task.isCancelled
    }

    /// A queued question that ended without an answer starting (cancelled, nothing heard):
    /// its tile goes rather than working forever. Also the flow's end.
    private func end(_ flow: QuestionFlow) {
        if currentFlow === flow { currentFlow = nil }
        shadowRoute(flow)
        flow.pendingSnipView?.text.cancel()  // left over if the run never took it
        flow.pendingSnipView?.objects.cancel()
        flow.pendingSnipView = nil
        guard let id = flow.jobID, !flow.joined, backgroundJobs?.job(id)?.isWorking == true else { return }
        backgroundJobs?.remove(id)
        Log.ask.notice("Peel dropped: the question ended before an answer started (\(id.uuidString, privacy: .public))")
    }

    // MARK: IntentRouter, shadow mode (C3)

    /// Off with `defaults write org.clickbait.ClickBait router.shadow -bool false`.
    private static var routerShadowOn: Bool { UserDefaults.standard.object(forKey: "router.shadow") as? Bool ?? true }
    private var routeCache = IntentRouter.Cache()
    private var shadowTask: Task<Void, Never>?

    /// After a question ends: what the router would have done, logged next to what ClickBait
    /// did. Changes nothing. Waits until ClickBait is idle (it never shares the GPU with an
    /// answer) and gives up if another question starts.
    private func shadowRoute(_ flow: QuestionFlow) {
        guard Self.routerShadowOn, let question = flow.heard, !question.isEmpty, let provider = flow.provider else { return }
        let actual: IntentRouter.Intent
        if tutorial?.isActive == true { actual = .tutorial }
        else if flow.kind == .command { actual = .order }
        else if flow.kind == .instantPick || flow.pointed { actual = .point }
        else { actual = .answer }
        let context = flow.context
        shadowTask?.cancel()
        shadowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, self.state == .idle, self.currentFlow == nil else { return }
            let start = ContinuousClock.now
            var route = self.routeCache.route(for: question)
            let cached = route != nil
            if route == nil {
                var ask = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0, context: context)
                ask.routeIntent = true
                let apps = Array(AppLocator.installed().keys)
                // Checked, then one retry on a bad reply (LTK's pattern); no bigger local model to escalate to yet.
                for _ in 0..<2 where route == nil {
                    guard self.state == .idle, !Task.isCancelled else { return }
                    let reply = await Self.reply(from: provider, to: ask, within: ProviderOperation.classifyRequest.timeout)
                    route = reply.flatMap { IntentRouter.parse($0, apps: apps) }
                }
                if let route { self.routeCache.store(route, for: question) }
            }
            let comparison = IntentRouter.Comparison(route: route, actual: actual)
            Log.ask.notice("""
                Router (shadow): \(comparison.summary, privacy: .public) in \(String(describing: ContinuousClock.now - start), privacy: .public)\
                \(cached ? " (cached)" : "", privacy: .public)
                """)
        }
    }

    /// A problem with the question: shown by the companion, or on the tile if it was sent away.
    private func report(_ message: String, for flow: QuestionFlow) {
        guard let id = flow.jobID, !flow.joined else {
            show(error: message)
            return
        }
        backgroundJobs?.fail(id, reason: message)
        Log.ask.notice("Peel failed before an answer started: \(message, privacy: .private)")
    }

    /// Checks shared by ask and explain. Shows the reason and returns false if blocked.
    private func checkCanAsk(frontmost: NSRunningApplication?) -> Bool {
        if settings.blocklist.isBlocked(bundleID: frontmost?.bundleIdentifier) {
            let name = frontmost?.localizedName ?? "this app"
            Log.ask.notice("Refused: frontmost app is on the blocklist")
            show(error: "ClickBait doesn't look at \(name) — it's on your blocklist.")
            return false
        }
        guard CGPreflightScreenCaptureAccess() else {
            show(error: "Screen Recording is off. Open Permissions… from the menu bar icon.")
            return false
        }
        return true
    }

    private func finish() async {
        guard state == .listening, let pressedAt, let flow = currentFlow else { return }
        defer { end(flow) }
        let held = ContinuousClock.now - pressedAt
        guard held >= Self.minimumHold else {
            cancel(reason: "hold was too short")
            return
        }

        let releasedAt = ContinuousClock.now
        try? await Task.sleep(for: Self.releaseTail)
        // A ⌃⌥ press during the tail already ended it (`endTail`).
        if flow.samples == nil {
            guard state == .listening else { return }  // cancelled meanwhile
            endTail(flow, releasedAt: releasedAt)
        }
        guard let samples = flow.samples else { return }
        let captureTask = flow.captureTask
        let snapshotTask = flow.snapshotTask

        let capture: ScreenCapture
        do {
            guard let captureTask else { throw CancellationError() }
            capture = try await captureTask.value
        } catch {
            Log.capture.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            report("Couldn't capture the screen: \(error.localizedDescription)", for: flow)
            return
        }

        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let audio = AudioConditioner.condition(samples, sampleRate: AudioRecorder.sampleRate)
        Log.ask.notice("""
            Audio level: peak \(audio.peak, format: .fixed(precision: 3), privacy: .public), \
            rms \(audio.rms, format: .fixed(precision: 4), privacy: .public), gain \(audio.gain, format: .fixed(precision: 1), privacy: .public)x\
            \(audio.isSilent ? " — silent" : "", privacy: .public)
            """)
        Log.ask.notice("""
            Captured \(samples.count, privacy: .public) samples (\(seconds, format: .fixed(precision: 2), privacy: .public)s), \
            screenshot \(capture.image.width, privacy: .public)x\(capture.image.height, privacy: .public)px \
            of display \(capture.displayID, privacy: .public) at \(capture.backingScale, privacy: .public)x
            """)

        if let snapshot = await snapshotTask?.value {
            flow.context.windowTitle = snapshot.windowTitle
            flow.context.windowFrame = snapshot.windowFrame
            flow.context.focusedElement = snapshot.focusedElement
            if currentFlow === flow { context = flow.context }
        }

        // Downscale and list what's clickable while Whisper runs.
        let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(capture.image) }
        let pid = flow.homePID
        let elementsTask = Task { await Self.elements(in: capture, frontmostPID: pid) }

        guard !audio.isSilent else {
            report("I didn't hear anything. Check the microphone, hold ⌃⌥ and try again.", for: flow)
            return
        }
        let transcript: String
        do {
            let start = ContinuousClock.now
            transcript = try await speech.transcribe(audio.samples)
            Log.ask.notice("""
                Transcribed \(seconds, format: .fixed(precision: 2), privacy: .public)s of audio in \
                \(String(describing: ContinuousClock.now - start), privacy: .public): \(transcript.count, privacy: .public) characters
                """)
        } catch {
            Log.ask.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            report("Couldn't understand the recording: \(error.localizedDescription)", for: flow)
            return
        }

        if settings.keepDebugCaptures {
            await Task.detached(priority: .utility) {
                do {
                    try DebugCaptureStore.save(capture, samples: samples, transcript: transcript)
                } catch {
                    Log.capture.error("Debug save failed: \(error.localizedDescription, privacy: .public)")
                }
            }.value
        }

        guard !Task.isCancelled else { return }
        guard !transcript.isEmpty else {
            report("I didn't catch that. Hold Control+Option and try again.", for: flow)
            return
        }
        flow.heard = transcript
        if let id = flow.jobID { backgroundJobs?.rename(id, to: transcript) }
        // A day answers a reminder's "when?"; "cancel" drops it; anything else replaces it.
        if pendingReminder != nil {
            if let day = ReminderDay.parse(transcript) {
                encoding.cancel()
                flow.kind = .command
                guard await settleQuick(flow, resolvesPending: true) else { return }
                await resolveReminder(day)
                return
            }
            let cancelled = CommandParser.confirmation(transcript) == false
            dropPendingReminder()
            if cancelled {
                encoding.cancel()
                return
            }
        }
        // "yes" / "cancel" answers a pending question; anything else replaces it.
        if pendingAction != nil {
            if let answer = CommandParser.confirmation(transcript) {
                encoding.cancel()
                flow.kind = .command
                guard await settleQuick(flow, resolvesPending: true) else { return }
                await resolvePending(answer)
                return
            }
            dropPending()
        }
        if flow.jobID == nil { onTranscript?(transcript) }

        if NoteReference.asksToSeeNote(transcript), ActionExecutor.lastNoteID.withLock({ $0 }) != nil {
            encoding.cancel()
            flow.kind = .command
            guard await settleQuick(flow) else { return }
            let reply = await showLastNote(speak: true)
            if chatShown, let reply {
                onChatUserMessage?(transcript)
                onChatReply?(reply)
            }
            return
        }

        // Direct orders run right away, without the model.
        if settings.commandsEnabled,
           let command = CommandParser.parse(transcript, allowedShortcuts: settings.allowedShortcuts),
           !isUnknownApp(command) {
            Log.ask.notice("Command recognised: \(command.name, privacy: .public)")
            encoding.cancel()
            flow.kind = .command
            guard await settleQuick(flow) else { return }
            if let action = asksFirst(command) {
                await handleOrder(action, request: command, speak: true, from: .clearOrder)
                return
            }
            _ = await perform(command)  // the outcome is already shown and spoken
            return
        }

        // An order in other words: ask the model which action it is (text only, ~1 s).
        flow.phase = .orderCheck
        let understood = await understandOrder(transcript, flow: flow)
        guard !Task.isCancelled else { return }  // Esc while checking
        if let (order, proposal) = understood {
            encoding.cancel()
            flow.kind = .command
            guard await settleQuick(flow) else { return }
            let message: String
            switch order {
            case .ready(let action): message = await handleOrder(action, request: proposal, speak: true, from: .modelGuess)
            case .failed(let reason):
                message = reason
                speaker.speak(reason)
                show(error: reason)
            }
            if chatShown {
                onChatUserMessage?(transcript)
                onChatReply?(message)
            }
            return
        }

        // "How do I…" with several clicks: walk them through it on screen.
        let elements = await elementsTask.value
        if await startTutorial(question: transcript, capture: capture, encoding: encoding, elements: elements,
                               speak: true, display: transcript, flow: flow) { return }
        flow.kind = .unknown  // not a walkthrough after all

        // With a chat open, a spoken question is a follow-up in it.
        await respond(question: transcript, selectedText: nil, capture: capture, encoding: encoding, startedAt: releasedAt,
                      speak: true, display: transcript, elements: elements, flow: flow)
    }

    // MARK: - Explain highlighted text (⌥⌘)

    private func explain() {
        stopRefining()
        tutorial?.stop(message: nil)
        guard state != .listening, state != .thinking, !isAnswering else { return }
        speaker.stop()
        if let open = conversation {
            // The explanation isn't a follow-up, so the chat is let go of now — but its
            // window stays until the double-tap window passes (a second tap puts it back).
            if chatShown { detachedChat = (open, snipMemory) }
            closeChat()
            if detachedChat == nil { onChatClose?() }
        }
        errorResetTask?.cancel()

        let frontmost = NSWorkspace.shared.frontmostApplication
        guard checkCanAsk(frontmost: frontmost) else { return }
        guard AXInspector.isTrusted else {
            show(error: "Explaining highlighted text needs Accessibility. Open Permissions… from the menu bar icon.")
            return
        }

        let pid = frontmost?.processIdentifier
        frontmostPID = pid
        context = ScreenContext(appName: frontmost?.localizedName)
        let provider = settings.makeProvider()
        self.provider = provider
        Task.detached(priority: .userInitiated) { await provider.warmUp() }
        state = .thinking
        Log.ask.notice("Explain requested (frontmost: \(frontmost?.bundleIdentifier ?? "none", privacy: .private))")
        askTask = Task { await finishExplain(pid: pid) }
    }

    private func finishExplain(pid: pid_t?) async {
        let startedAt = ContinuousClock.now
        let snapshot = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid) }.value
        guard !Task.isCancelled else { return }
        // The ⌘C fallback waits out a possible second tap: a double tap opens the chat and
        // needs no selection (it used to send ⌘C on the first tap).
        guard let (selected, method) = await SelectionReader.read(frontmostPID: pid, accessibilitySelection: snapshot.selectedText,
                                                                  beforeCopy: { [weak self] in
                                                                      await self?.explainCommit?.value
                                                                      return !Task.isCancelled
                                                                  })
        else {
            Log.ask.notice("Explain: no selection found (accessibility and copy both empty)")
            // Not while a second tap could still come: a double tap needs no selection.
            await explainCommit?.value
            guard !Task.isCancelled else { return }
            show(error: "Highlight text and tap ⌥⌘ — or hold ⌥⌘ and circle or drag a box around something.")
            return
        }
        guard !Task.isCancelled else { return }
        context.windowTitle = snapshot.windowTitle
        context.windowFrame = snapshot.windowFrame
        context.focusedElement = snapshot.focusedElement
        Log.ask.notice("Explain: \(selected.count, privacy: .public) characters selected via \(method.rawValue, privacy: .public)")
        if isExplainProvisional { pendingExcerpt = selected } else { onExplaining?(selected) }

        let capture: ScreenCapture
        do {
            capture = try await capturer.captureDisplayUnderCursor(excluding: settings.blocklist,
                                                                   ignoreClickBait: settings.ignoreNotchInCaptures)
        } catch {
            Log.capture.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            show(error: "Couldn't capture the screen: \(error.localizedDescription)")
            return
        }
        let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(capture.image) }
        let excerpt = selected.count > 120 ? selected.prefix(119) + "…" : Substring(selected)
        // Explanations are read, not heard: you didn't use your voice.
        await respond(question: "", selectedText: selected, capture: capture, encoding: encoding, startedAt: startedAt,
                      speak: false, display: "Explain: “\(excerpt)”")
    }

    /// The microphone's level while listening, for the waveform.
    var microphoneLevel: Float { state == .listening ? recorder.level : 0 }

    // MARK: - Proposed actions (phase E, step 4)

    /// A risky action the model proposed, waiting for the user's yes.
    @ObservationIgnored private var pendingAction: (request: ActionRequest, speak: Bool, inChat: Bool)?
    /// A reminder waiting for its day (Today / Tomorrow / a spoken or typed day).
    @ObservationIgnored private var pendingReminder: (request: ActionRequest, speak: Bool, inChat: Bool)?
    /// A reminder's "when?" card should be shown: the question, the buttons, a hint.
    @ObservationIgnored var onReminderDayRequest: ((String, [String], String?) -> Void)?
    /// The card's buttons, in order.
    private static let reminderDayChoices: [ReminderDay] = [.inDays(0), .inDays(1)]

    private func askReminderDay(_ request: ActionRequest, speak: Bool) -> ActionOutcome {
        dropPending()
        pendingReminder = (request, speak, chatShown)
        let title = ReminderText.parse(request.detail ?? "").title
        let question = "“\(title)” — when?"
        Log.ask.notice("Reminder: no day said, asking")
        if speak { speaker.speak("When should I remind you?") }
        if state == .thinking { state = .idle }
        onReminderDayRequest?(question, ["Today", "Tomorrow"], "or say a day")
        return .asked(question)
    }

    /// The card's answer: a button's index, or nil when it timed out.
    func answerReminderChoice(_ index: Int?) {
        guard let index, Self.reminderDayChoices.indices.contains(index) else {
            dropPendingReminder(timedOut: true)
            return
        }
        Task { await resolveReminder(Self.reminderDayChoices[index]) }
    }

    /// A day picked on the card's calendar.
    func answerReminderDate(_ date: Date) {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)).day ?? 0
        Task { await resolveReminder(.inDays(max(days, 0))) }
    }

    private func resolveReminder(_ day: ReminderDay) async {
        guard var pending = pendingReminder else { return }
        pendingReminder = nil
        onConfirmEnd?()
        pending.request.detail = (pending.request.detail ?? "") + " " + day.phrase
        let outcome = await perform(pending.request, speak: pending.speak)
        if pending.inChat, chatShown, case .success(let confirmation) = outcome { onChatReply?(confirmation + ".") }
    }

    private func dropPendingReminder(timedOut: Bool = false) {
        guard pendingReminder != nil else { return }
        pendingReminder = nil
        onConfirmEnd?()
        Log.ask.notice("Reminder: no day given, not added\(timedOut ? " (timed out)" : "", privacy: .public)")
        if timedOut { show(error: "Reminder not added — no day was picked.") }
    }

    /// A clear order that `ActionPolicy` says asks first (binning files, quitting an app), or nil.
    private func asksFirst(_ command: ActionRequest) -> ResolvedAction? {
        guard case .success(let action) = ActionCatalog.resolve(command, allowedShortcuts: settings.allowedShortcuts),
              ActionPolicy.decide(action, from: .clearOrder) == .ask else { return nil }
        return action
    }

    /// An order, said clearly or guessed by the model: `ActionPolicy` decides whether it runs
    /// now or is asked about first. Returns what to show in the chat: the question asked, or
    /// the result.
    @discardableResult
    private func handleOrder(_ action: ResolvedAction, request proposal: ActionRequest, speak: Bool,
                             from source: ActionPolicy.Source) async -> String {
        if ActionPolicy.decide(action, from: source) == .ask {
            var count: Int?
            if case .file = action { count = try? await FinderSelection.read().count }
            if count == 0 {
                let message = FileActionError.nothingSelected.localizedDescription
                if speak { speaker.speak(message) }
                show(error: message)
                return message
            }
            pendingAction = (proposal, speak, chatShown)
            let question = ActionCatalog.confirmationQuestion(for: action, fileCount: count)
            Log.ask.notice("Order \(proposal.name, privacy: .public) (\(source.rawValue, privacy: .public)): asking first")
            if speak { speaker.speak(question) }
            if state == .thinking { state = .idle }
            onConfirmRequest?(question)
            return question
        }
        Log.ask.notice("Order \(proposal.name, privacy: .public) (\(source.rawValue, privacy: .public)): running")
        switch await perform(proposal, speak: speak) {
        case .success(let confirmation): return confirmation + "."
        case .failure(let message): return message
        case .asked(let question): return question
        }
    }

    /// The whole reply to `request`, or nil if it fails or takes longer than `limit`.
    nonisolated static func reply(from provider: any LLMProvider, to request: AskRequest, within limit: Duration) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var text = ""
                do { for try await chunk in provider.stream(request) { text += chunk } } catch { return nil }
                return text
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// "suggested next:" for a finished background answer's card: one short text-only
    /// request (`Prompt.nextSystem`, ~1 s). Nil if it's slow (Ollama may be busy with a
    /// question: a foreground answer comes first) or the reply isn't usable.
    func suggestNext(question: String, answer: String) async -> [String]? {
        var ask = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: ScreenContext(appName: nil), selectedText: nil)
        ask.suggestNextAfter = MessageFormat.spokenText(answer)
        let start = ContinuousClock.now
        let reply = await Self.reply(from: settings.makeProvider(), to: ask, within: .seconds(4))
        let suggestions = reply.flatMap { NextSuggestions.parse($0, question: question) }
        Log.ask.notice("Suggested next: \(suggestions?.count ?? -1) in \(String(describing: ContinuousClock.now - start), privacy: .public)")
        return suggestions
    }

    /// A card's [voice]: listening as if ⌃⌥ were held, until the next click (or 20 s),
    /// which counts as letting go.
    func listenUntilClick() {
        guard !isBusy else { return }
        handle(.askPressed)
        guard state == .listening else { return }
        var monitors: [Any] = []
        var done = false
        let finish: @MainActor () -> Void = { [weak self] in
            guard !done else { return }
            done = true
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            guard let self, state == .listening else { return }
            handle(.askReleased)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { _ in
            MainActor.assumeIsolated { finish() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in
            MainActor.assumeIsolated { finish() }
            return event
        }) { monitors.append(local) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            finish()
        }
    }

    /// For orders the rules don't recognise ("stash these in my documents"): a quick,
    /// text-only request asking which known action it is. Nil if none (or no answer in
    /// time); the result still has to pass the catalog and the Finder check.
    enum UnderstoodOrder {
        case ready(ResolvedAction)
        /// Understood, but can't be done (the reason, for the user).
        case failed(String)
    }

    private func understandOrder(_ text: String, flow: QuestionFlow? = nil) async -> (UnderstoodOrder, ActionRequest)? {
        guard settings.commandsEnabled, CommandParser.looksLikeOrder(text), let provider = flow?.provider ?? self.provider else { return nil }
        let context = flow?.context ?? self.context
        // "Show me how to…" and "open YouTube" are walkthroughs, not orders: reading
        // "show me how to open youtube on chrome" as "open Chrome" just opened Chrome.
        if TutorialQuestion.asksForTutorial(text) || Websites.visit(in: text, installedApps: Array(AppLocator.installed().keys)) != nil {
            Log.ask.notice("Order check: skipped (a walkthrough)")
            return nil
        }
        // "Where's / show me / point at X" is never an order: don't spend ~1.5 s asking.
        if TutorialQuestion.isLocatingRequest(text) {
            Log.ask.notice("Order check: skipped (finding something)")
            return nil
        }
        let start = ContinuousClock.now
        var request = AskRequest(question: text, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0, context: context)
        request.interpretOrder = true
        let reply = await Self.reply(from: provider, to: request, within: ProviderOperation.interpretOrder.timeout)
        guard let reply, let parsed = ResponseParser.action(inReply: reply),
              var proposal = OrderCheck.sanitized(parsed, order: text) else {
            Log.ask.notice("Order check: no action (\(String(describing: ContinuousClock.now - start), privacy: .public))")
            return nil
        }
        // Not Finder in front, or an app name that isn't installed: maybe it wasn't an
        // order after all ("open the File menu") — answer it normally.
        guard !isUnknownApp(proposal) else {
            Log.ask.notice("Order check: \(proposal.name, privacy: .public) doesn't apply here")
            return nil
        }
        // "Add it to my notes": the note is resolved from the user's words (the model's
        // detail is a guess at "it"), when they refer to the page, selection or answer.
        if proposal.name == "make_note" || proposal.name == "add_reminder", NoteReference.find(in: text) != nil {
            proposal.detail = text
        }
        let action: ResolvedAction
        switch ActionCatalog.resolve(proposal, allowedShortcuts: settings.allowedShortcuts) {
        case .success(let resolved): action = resolved
        case .failure(let error):
            // An order ClickBait understood but can't carry out: say why, don't quietly
            // turn it into a how-to.
            Log.ask.notice("Order check: \(proposal.name, privacy: .public) can't be done (\(String(describing: error), privacy: .private))")
            return (.failed(error.message), proposal)
        }
        Log.ask.notice("Order check: \(proposal.name, privacy: .public) (\(String(describing: ContinuousClock.now - start), privacy: .public))")
        return (.ready(action), proposal)
    }

    /// The user's answer to a pending question (Do it / Cancel, "yes" / "cancel", Esc).
    func answerConfirmation(_ yes: Bool) {
        Task { await resolvePending(yes) }
    }

    private func resolvePending(_ yes: Bool) async {
        guard let pending = pendingAction else { return }
        pendingAction = nil
        onConfirmEnd?()
        guard yes else {
            Log.ask.notice("Proposed action cancelled")
            if pending.speak { speaker.speak("Okay, I won't.") }
            if state == .thinking { state = .idle }
            return
        }
        let outcome = await perform(pending.request, speak: pending.speak)
        if pending.inChat, chatShown, case .success(let confirmation) = outcome { onChatReply?(confirmation + ".") }
    }

    private func dropPending() {
        guard pendingAction != nil else { return }
        pendingAction = nil
        onConfirmEnd?()
    }

    // MARK: - Tutorials

    /// Set by the app delegate: walks the user through multi-step how-tos.
    @ObservationIgnored var tutorial: TutorialController?

    /// The app the user was in when a tutorial had to open another one ("back to Notes?").
    @ObservationIgnored private(set) var tutorialReturnApp: NSRunningApplication?
    /// Setup (opening an app for a tutorial) is over: the green "Opening…" can go.
    @ObservationIgnored var onSetupFinished: (() -> Void)?
    /// A walkthrough is being planned (true: lavender, spinning), or won't happen (false).
    @ObservationIgnored var onTutorialPlanning: ((Bool) -> Void)?
    /// The walkthrough being planned now was sent to the dock (Lavender's hold, as a snip's
    /// Strawberry Red one): its plan goes to that tile, never to the foreground.
    @ObservationIgnored private var walkthroughJobID: UUID?
    /// Planning is under way and may be held in the dock (`PeelRule.holdPeels`).
    @ObservationIgnored private var walkthroughPlanning = false
    /// A walkthrough was just declined: the answer that follows is words only — no app is
    /// opened and nothing is pointed at (2026-10-14: after a lapsed "show me in Safari!" the
    /// fallback answer opened Safari and pointed at its menu bar).
    @ObservationIgnored private var answerInWordsOnly = false
    /// A hotkey brought ClickBait up (⌃⌥ held, ⌥⌘ tapped or double-tapped): the chat's
    /// place is where the companion is at this moment.
    @ObservationIgnored var onInvoked: (() -> Void)?
    @ObservationIgnored private var tutorialPlanningShown = false

    /// "[show me!] [✕]" should be offered before a walkthrough starts (the button's words).
    @ObservationIgnored var onTutorialOffer: ((String) -> Void)?
    /// A walkthrough was declined: its steps, written out for the chat.
    @ObservationIgnored var onStepsWritten: ((String) -> Void)?
    @ObservationIgnored private var pendingOffer: CheckedContinuation<Bool, Never>?

    /// Asks before a walkthrough takes over the pointer or opens another app. ✕, Esc or 8 s
    /// without a click is a no.
    private func offerWalkthrough(opening app: String?) async -> Bool {
        showTutorialPlanning()
        answerOffer(false)  // never two at once
        let label = app.map { "show me in \($0)!" } ?? "show me!"
        Log.ask.notice("Tutorial: offering (\(label, privacy: .public))")
        let yes = await withCheckedContinuation { continuation in
            pendingOffer = continuation
            onTutorialOffer?(label)
        }
        Log.ask.notice("Tutorial: \(yes ? "show me" : "declined", privacy: .public)")
        return yes && !Task.isCancelled
    }

    /// The offer's answer (its pill, Esc, a timeout, anything that replaces it).
    func answerOffer(_ yes: Bool) {
        guard let pending = pendingOffer else { return }
        pendingOffer = nil
        pending.resume(returning: yes)
    }

    /// Declined: the plan's steps in the chat instead of the pointer.
    private func writeSteps(_ plan: TutorialPlan, question: String, display: String) {
        let text = (plan.intro.isEmpty ? "" : plan.intro + "\n\n") + plan.checklist(done: 0)
        if conversation == nil || !chatShown {
            conversation = Conversation()
            snipMemory = nil
            chatShown = true
            onChatOpen?(display)
        } else {
            onChatUserMessage?(display)
        }
        conversation?.append(user: question, assistantSpeech: text)
        if state == .thinking { state = .idle }
        onStepsWritten?(text)
    }

    // MARK: Lavender's hold (as Strawberry Red's: `PeelRule.Hold`)

    /// Planning has begun: still at it after `autoPeelDelay`, it goes to the dock.
    private func startWalkthroughHold(question: String) {
        walkthroughPlanning = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: PeelRule.autoPeelDelay)
            guard let self, walkthroughPlanning, walkthroughJobID == nil else { return }
            let room = backgroundJobs?.hasRoom ?? false
            guard PeelRule.holdPeels(.walkthrough, stillWorking: true, hasRoom: room) else {
                Log.ask.notice("Walkthrough hold: three's a crowd, planning in front")
                return
            }
            peelWalkthrough(question: question)
        }
    }

    /// The planning goes to a Lavender tile: the companion flies there and a fresh one is at
    /// the cursor (the hold ends for the foreground); the plan carries on in the background and
    /// nothing is pointed at or opened until "show me!".
    private func peelWalkthrough(question: String) {
        guard let backgroundJobs else { return }
        let job = BackgroundJob(question: question, kind: .walkthrough, homeBundleID: frontmostBundleID, homePID: frontmostPID,
                                conversation: conversation ?? Conversation())
        guard backgroundJobs.add(job, task: askTask) else { return }
        walkthroughJobID = job.id
        _ = onPeel?(job)
        // The task belongs to the tile now: Esc or a new question mustn't cancel it.
        askTask = nil
        if tutorialPlanningShown { onTutorialPlanning?(false) }
        tutorialPlanningShown = false
        speaker.stop()
        currentFlow = nil
        if state == .thinking { state = .idle }
        Log.ask.notice("Walkthrough hold: planning sent to the dock after \(String(describing: PeelRule.autoPeelDelay), privacy: .public)")
    }

    /// The plan is ready (or it needs its app first) in the dock: the card says what it'll do
    /// and offers "show me!".
    private func finishWalkthroughInDock(_ jobID: UUID, pending: PendingWalkthrough) {
        guard let backgroundJobs else { return }
        let text: String
        if let plan = pending.plan, !plan.steps.isEmpty, pending.app == nil {
            text = [plan.intro, plan.checklist(done: 0)].filter { !$0.isEmpty }.joined(separator: "\n")
        } else if let app = pending.app {
            text = "Ready to walk you through it in \(app). \"show me!\" opens \(app) and starts."
        } else {
            backgroundJobs.fail(jobID, reason: "Couldn't work out the steps.")
            return
        }
        backgroundJobs.setChatMessages([ChatModel.Message(role: .user, text: pending.display),
                                        ChatModel.Message(role: .assistant, text: text)], for: jobID)
        backgroundJobs.setWalkthrough(pending, for: jobID)
        backgroundJobs.complete(jobID, answer: text, conversation: conversation ?? Conversation())
        backgroundJobs.setLeadingSuggestion(PeelRule.resumeAction(.walkthrough), for: jobID)
        Log.ask.notice("Walkthrough hold: ready in the dock (\(pending.app == nil ? "steps planned" : "needs its app", privacy: .public))")
    }

    /// "show me!" on a walkthrough's card, once "go there!" has brought its window back: the
    /// walkthrough starts now (and only now may it open an app, as a step needs it).
    func resumeWalkthrough(_ pending: PendingWalkthrough) {
        guard let tutorial else { return }
        let apps = AppLocator.installed()
        let installedName = { (name: String) in apps.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } }
        let provider = self.provider ?? settings.makeProvider()
        self.provider = provider
        let frontmost = NSWorkspace.shared.frontmostApplication
        frontmostPID = frontmost?.processIdentifier
        frontmostBundleID = frontmost?.bundleIdentifier
        context = ScreenContext(appName: frontmost?.localizedName)
        Log.ask.notice("Walkthrough hold: resumed from the dock")
        askTask = Task {
            var plan = pending.plan
            // It happens in another app: open it now (the user said "show me!") and plan there,
            // in front — they're waiting for it, so no second hold.
            if let app = pending.app.flatMap(installedName), app.caseInsensitiveCompare(frontmost?.localizedName ?? "") != .orderedSame {
                tutorialPlanningShown = false
                showTutorialPlanning()
                defer { if tutorialPlanningShown, !(tutorial.isActive) { onTutorialPlanning?(false) }; tutorialPlanningShown = false }
                guard let ready = await openForTutorial(app, url: apps[app]) else { return }
                context = ScreenContext(appName: app)
                plan = await planTutorial(pending.question, capture: ready.0, screenshot: ready.1, elements: ready.2, provider: provider)?
                    .separatingSetup(frontmostApp: app, isInstalledApp: { installedName($0) != nil })
                guard let plan, !plan.steps.isEmpty else {
                    show(error: "Couldn't work out the steps in \(app).")
                    return
                }
                _ = await beginTutorial(plan, question: pending.question, startedIn: frontmost, speak: false,
                                        display: pending.display, installedName: installedName, apps: apps,
                                        provider: provider, tutorial: tutorial)
                return
            }
            guard let plan, !plan.steps.isEmpty else { return }
            _ = await beginTutorial(plan, question: pending.question, startedIn: frontmost, speak: false,
                                    display: pending.display, installedName: installedName, apps: apps,
                                    provider: provider, tutorial: tutorial)
        }
    }

    /// Lavender and spinning from the moment it's known to be a walkthrough, not only once
    /// the steps are ready.
    private func showTutorialPlanning() {
        guard !tutorialPlanningShown else { return }
        tutorialPlanningShown = true
        onTutorialPlanning?(true)
    }

    /// "How do I…" or an order that takes clicks ("Clear search history."): plan the
    /// clicks and walk the user through them in lavender. If the task lives in another
    /// app, open it first (green). Returns false to answer normally instead.
    private func startTutorial(question: String, capture: ScreenCapture, encoding: Task<EncodedScreenshot, Error>,
                               elements: [ScreenElement], speak: Bool, display: String, flow: QuestionFlow? = nil) async -> Bool {
        // Lavender while planning, once an app was opened for the walkthrough (green →
        // lavender, not green → idle blue → lavender). Dropped again if no tutorial starts.
        // A queued question until it is settled: not the foreground's, so it neither shows nor
        // clears the planning colour, and reads its own context, provider and app.
        var ownsPlanningUI = flow?.jobID == nil
        let context = flow?.context ?? self.context
        let homePID = flow?.homePID ?? frontmostPID
        let provider = flow?.provider ?? self.provider
        if ownsPlanningUI { tutorialPlanningShown = false }
        defer {
            if ownsPlanningUI {
                if tutorialPlanningShown, !(tutorial?.isActive ?? false) { onTutorialPlanning?(false) }
                tutorialPlanningShown = false
            }
        }
        // "Where" is showing where: always a blue point, never a walkthrough.
        if TutorialQuestion.asksWhere(question) { return false }
        let asking = TutorialQuestion.asksForTutorial(question)
        let ordering = !asking && CommandParser.looksLikeOrder(question) && !TutorialQuestion.isContentRequest(question)
            && !TutorialQuestion.isLocatingRequest(question)  // "show me the refresh button": blue pointing
        // A well-known website is typed into the browser (lavender) however it's asked,
        // even "show me how to open YouTube"; other "show me…" requests point (blue).
        let visiting = Websites.visit(in: question, installedApps: Array(AppLocator.installed().keys)) != nil
        // "System Setting" on its own: getting there is the task (Apple menu → System Settings…).
        let toSystemSettings = TutorialQuestion.onlyOpens(question, app: "System Settings")
            && TutorialQuestion.taskApp(in: question, apps: Array(AppLocator.installed().keys)) == "System Settings"
        // "Where's / show me X" is showing where (blue), not how (lavender) — unless getting to
        // X takes more than one click: X is an item inside this app's menus, or a thing
        // (not a control) in another app the request names ("show me my Safari history").
        // Decided before any colour changes, so a "where" never flashes lavender.
        var findingHidden = false
        if TutorialQuestion.isLocatingRequest(question), !Self.isOnScreen(question, in: elements),
           !TutorialQuestion.namesControl(question) {
            let named = TutorialQuestion.mentionedApp(in: question, apps: Array(AppLocator.installed().keys))
            if let named, named.caseInsensitiveCompare(context.appName ?? "") != .orderedSame {
                findingHidden = true
            } else if let target = InstantAnswer.locateTargets(in: question).first {
                let pid = homePID
                let path = await Task.detached(priority: .userInitiated) { AXInspector.menuPath(to: target, frontmostPID: pid) }.value
                findingHidden = (path?.count ?? 0) >= 2
            }
        }
        guard asking || ordering || visiting || toSystemSettings || findingHidden, let provider, let tutorial else { return false }
        // A walkthrough isn't sent away: a queued peel's tile goes and it runs once the foreground is free.
        if let flow {
            flow.kind = .command
            guard await settleQuick(flow) else { return true }
            ownsPlanningUI = true
            tutorialPlanningShown = false
        }
        if findingHidden { Log.ask.notice("Tutorial: what they're looking for isn't on screen; walking them there") }
        let startedIn = NSWorkspace.shared.frontmostApplication
        let apps = AppLocator.installed()
        // The installed app's own name ("Safari"), whatever case the plan wrote.
        let installedName = { (name: String) in apps.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } }
        var capture = capture
        var elements = elements
        var screenshot: EncodedScreenshot
        do { screenshot = try await encoding.value } catch { return false }
        tutorialReturnApp = nil

        // "Go to YouTube": an order, not a how-to — ClickBait just does it (green), switching
        // to a tab already showing the site or opening it. "Show me how to open YouTube" (and
        // "…and play lofi", with more to do) stays a walkthrough.
        if !asking, let site = Websites.visit(in: question, installedApps: Array(apps.keys)),
           Websites.isJustAVisit(question, site: site.name),
           let browser = Websites.namedBrowser(in: question, installed: Array(apps.keys)) ?? AppLocator.defaultBrowserName() {
            await visitWebsite(site, in: browser, appURL: apps[browser])
            return true
        }

        // The task's app isn't in front. Either the request names it ("my Safari history")
        // or it's a Mac setting. Planning those from the app in front walked Finder's own
        // "Settings…", so the app is opened first and the plan made there.
        let taskApp = TutorialQuestion.taskApp(in: question, apps: Array(apps.keys))
        // System Settings is shown, not opened for the user: the Apple menu, then "System
        // Settings…" (works from any app, no model needed); once it's open, the rest of the
        // task is planned in there — unless getting there was the whole request.
        if taskApp == "System Settings", context.appName?.caseInsensitiveCompare("System Settings") != .orderedSame {
            // Known settings go on to their page and control (`SystemSettingsMap`): facts,
            // where the model sent Night Shift to General.
            let route = SystemSettingsMap.route(for: question) ?? []
            Log.ask.notice("Tutorial: System Settings by the Apple menu\(route.isEmpty ? "" : " → " + route.joined(separator: " → "), privacy: .public)")
            let settingsPlan = TutorialPlan.systemSettingsByAppleMenu(from: context.appName, route: route)
            guard await offerWalkthrough(opening: nil) else {
                writeSteps(settingsPlan, question: question, display: display)
                return true
            }
            return await beginTutorial(settingsPlan, question: question, startedIn: startedIn,
                                       speak: speak, display: display, installedName: installedName, apps: apps,
                                       provider: provider, tutorial: tutorial,
                                       continues: !TutorialQuestion.onlyOpens(question, app: "System Settings"))
        }
        // Said yes already ("show me in Safari!"): never asked a second time.
        var offered = false
        if let named = taskApp, named.lowercased() != context.appName?.lowercased() {
            // It happens in another app, and no app opens during Lavender's hold: to the dock
            // (as a snip's Strawberry Red hold), where "show me!" opens it and plans there.
            if ownsPlanningUI, PeelRule.holdPeels(.walkthrough, stillWorking: true, hasRoom: backgroundJobs?.hasRoom ?? false) {
                showTutorialPlanning()
                try? await Task.sleep(for: PeelRule.autoPeelDelay)
                guard !Task.isCancelled else { return true }
                peelWalkthrough(question: question)
                if let jobID = walkthroughJobID {
                    walkthroughJobID = nil
                    finishWalkthroughInDock(jobID, pending: PendingWalkthrough(plan: nil, app: named, question: question, display: display))
                }
                return true
            }
            // A full dock: ask in front before switching apps (no plan yet: it's made in that app),
            // so a no gets a written answer instead.
            guard await offerWalkthrough(opening: named) else {
                answerInWordsOnly = true
                return false
            }
            offered = true
            guard let ready = await openForTutorial(named, url: apps[named]) else { return false }
            showTutorialPlanning()
            (capture, screenshot, elements) = ready
        }

        // A well-known website ("open YouTube", "I want to watch YouTube"): one typing step
        // in the browser's address bar, with the address from ClickBait's own list — no
        // model, so it's instant and never a guessed domain. Whatever's left once the page
        // is open ("…and play lofi") is planned from there.
        if let site = Websites.visit(in: question, installedApps: Array(apps.keys)),
           let browser = Websites.namedBrowser(in: question, installed: Array(apps.keys)) ?? AppLocator.defaultBrowserName() {
            let step = TutorialStep(target: "address bar", instruction: "Type \(site.address), then press Return",
                                    app: browser, typing: site.address)
            let plan = TutorialPlan(intro: "Type \(site.name)'s address in \(browser).", steps: [step])
            Log.ask.notice("Tutorial: website \(site.address, privacy: .public) in the browser")
            let switching = browser.caseInsensitiveCompare(context.appName ?? "") != .orderedSame
            guard await offerWalkthrough(opening: switching ? browser : nil) else {
                writeSteps(plan, question: question, display: display)
                return true
            }
            return await beginTutorial(plan, question: question, startedIn: startedIn, speak: speak, display: display,
                                       installedName: installedName, apps: apps, provider: provider, tutorial: tutorial,
                                       continues: !Websites.isJustAVisit(question, site: site.name))
        }

        var plan: TutorialPlan?
        for _ in 0..<2 {
            guard !Task.isCancelled else { return false }
            plan = await planTutorial(question, capture: capture, screenshot: screenshot, elements: elements, provider: provider,
                                      holdable: ownsPlanningUI && walkthroughJobID == nil)?
                .separatingSetup(frontmostApp: context.appName, isInstalledApp: { installedName($0) != nil })
            // The plan says it happens in another app: ask, then open it (green) and plan again there —
            // not while held in the dock (no app opens during a hold; "show me!" opens it later).
            guard walkthroughJobID == nil, let other = plan?.app.flatMap(installedName), let url = apps[other] else { break }
            if !offered {
                offered = true
                guard await offerWalkthrough(opening: other) else {
                    answerInWordsOnly = true
                    return false
                }
            }
            guard let ready = await openForTutorial(other, url: url) else { return false }
            showTutorialPlanning()
            (capture, screenshot, elements) = ready
        }
        if let jobID = walkthroughJobID {
            walkthroughJobID = nil
            let elsewhere = plan?.app.flatMap(installedName)
            finishWalkthroughInDock(jobID, pending: PendingWalkthrough(plan: plan, app: elsewhere, question: question, display: display))
            return true
        }
        guard !Task.isCancelled, let plan, let first = plan.steps.first else {
            onSetupFinished?()
            Log.ask.notice("Tutorial: no steps; answering normally")
            return false
        }
        Log.ask.notice("Tutorial steps: \(plan.steps.map { "\($0.target) [\($0.app ?? "-")]\($0.typing.map { " type " + $0 } ?? "")" }.joined(separator: " → "), privacy: .public)")
        // Its first click must be findable (on screen or in the app's menus).
        if StepMatcher.find(first.target, in: elements) == nil, !first.isShortcut {
            let pid = frontmostPID
            let inMenus = await Task.detached(priority: .userInitiated) {
                AXInspector.menuPath(to: first.target, frontmostPID: pid) != nil
            }.value
            guard inMenus else {
                onSetupFinished?()
                Log.ask.notice("Tutorial: first step (\(first.target, privacy: .public)) isn't on screen; answering normally")
                return false
            }
        }
        if !offered, !(await offerWalkthrough(opening: nil)) {
            writeSteps(plan, question: question, display: display)
            return true
        }
        return await beginTutorial(plan, question: question, startedIn: startedIn, speak: speak, display: display,
                                   installedName: installedName, apps: apps, provider: provider, tutorial: tutorial)
    }

    /// Goes to a well-known site (green): its tab if one's open, else a new page.
    private func visitWebsite(_ site: (name: String, address: String), in browser: String, appURL: URL?) async {
        onActionStarted?("opening \(site.name)…")
        let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == browser }
        if let running {
            let pid = running.processIdentifier
            let switched = await Task.detached(priority: .userInitiated) {
                AXInspector.selectTab(showing: site.name, browserPID: pid)
            }.value
            if switched {
                running.activate()
                Log.ask.notice("Website: switched to an open \(site.name, privacy: .public) tab in \(browser, privacy: .public)")
                onActionDone?("switched to \(site.name)")
                if state == .thinking { state = .idle }
                return
            }
        }
        guard let url = URL(string: site.address.hasPrefix("http") ? site.address : "https://" + site.address),
              let appURL else {
            show(error: "Couldn't open \(site.name).")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            Log.ask.notice("Website: opened \(site.address, privacy: .public) in \(browser, privacy: .public)")
            onActionDone?("opened \(site.name)")
        } catch {
            show(error: "Couldn't open \(site.name): \(error.localizedDescription)")
        }
        if state == .thinking { state = .idle }
    }

    /// A tour's stops on screen, labelled as guesses ("~ name"), each with the outline of the
    /// thing at its point where one stands out (found off the main thread).
    /// `known`: outlines the marks already have (close-up pixels, nil where they don't).
    private nonisolated static func tourPointers(_ stops: [Pointer], outlines known: [PartOutline?] = [], in view: SnipView) async -> [ScreenPointer] {
        let start = ContinuousClock.now
        let pointsPerPixel = view.crop.width / Double(view.image.width)
        let outlines = await Task.detached(priority: .userInitiated) {
            stops.enumerated().map { index, stop -> PartOutline? in
                if index < known.count, let outline = known[index] { return outline.scaled(by: pointsPerPixel) }
                return view.outlines(at: [stop]).first.flatMap { $0 }
            }
        }.value
        Log.ask.notice("Parts: outlines for \(outlines.compactMap { $0 }.count, privacy: .public) of \(stops.count, privacy: .public) in \(String(describing: ContinuousClock.now - start), privacy: .public) (the tip stops at their edges)")
        // Where each part is and how far its edges are, so a tip that's off can be read off:
        // the model's spot (close-up pixels) or the outline (points: nearest–farthest edge).
        for (stop, outline) in zip(stops, outlines) {
            let edges = outline.map { "edges \(Int($0.radii.min() ?? 0))–\(Int($0.radii.max() ?? 0)) pt" } ?? "no outline"
            Log.ask.notice("Parts: \(stop.label, privacy: .public) at \(Int(stop.x), privacy: .public),\(Int(stop.y), privacy: .public) of \(view.image.width, privacy: .public)×\(view.image.height, privacy: .public): \(edges, privacy: .public)")
        }
        return zip(stops, outlines).map { stop, outline in
            var pointer = view.screenPointer(Pointer(x: stop.x, y: stop.y, label: "~ " + stop.label.lowercased()))
            pointer.outline = outline
            return pointer
        }
    }

    /// Faces in a snip's close-up, found off the main thread.
    /// Starts finding the separate things in a snip's close-up, off the main thread.
    private nonisolated static func findObjects(in view: SnipView) -> Task<[FoundObject], Never> {
        let cancellation = ObjectFinder.CancellationFlag()
        return Task.detached(priority: .userInitiated) {
            await withTaskCancellationHandler {
                let start = ContinuousClock.now
                let objects = ObjectFinder.objects(in: view.image, marked: view.marked, cancellation: cancellation)
                Log.ask.notice("Objects: \(objects.count, privacy: .public) found in \(String(describing: ContinuousClock.now - start), privacy: .public)")
                return objects
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    struct WebLookupResult: Sendable {
        var passages: [WebPassage] = []
        var needsScreen = false
        /// "Sources: [Wikipedia — Swift](…) · …", for under the answer.
        var credit: String?
    }

    /// Internet Mode's fixed steps: the search words (local model, text only), then the
    /// sources at once (~4 s at most), then the passages closest to the question. Only the
    /// cleaned search words and page addresses leave the Mac (spec decisions 4–5).
    private func lookUp(question: String, reason: WebLookup.Reason, selectedText: String?, capture: ScreenCapture,
                        history: [ChatTurn], provider: any LLMProvider) async -> WebLookupResult {
        let start = ContinuousClock.now
        var result = WebLookupResult(needsScreen: WebLookup.refersToScreen(question))
        // What's on screen near the pointer, read on this Mac, for the query step only.
        var screenWords = ""
        if result.needsScreen {
            let boxes = await TextReader.read(capture.image)
            let mouse = NSEvent.mouseLocation
            let pointer = Point(x: (mouse.x - capture.displayFrame.minX) * capture.backingScale,
                                y: (capture.displayFrame.maxY - mouse.y) * capture.backingScale)
            func distance(_ point: Point) -> Double { hypot(point.x - pointer.x, point.y - pointer.y) }
            for box in boxes.sorted(by: { distance($0.center) < distance($1.center) }) {
                guard screenWords.count + box.text.count < 1_500 else { break }
                screenWords += (screenWords.isEmpty ? "" : " | ") + box.text
            }
        }
        let onScreen = [screenWords, context.windowTitle ?? "", selectedText ?? ""].joined(separator: "\n")
        let screenNames = OnDeviceLanguage.personalNames(in: onScreen)
        let earlier = history.last(where: { $0.role == .user }).map { Self.spokenQuestion(in: $0.content) }

        var ask = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: context, selectedText: selectedText)
        ask.lookupQuery = true
        ask.screenWords = screenWords.isEmpty ? nil : screenWords
        ask.earlierQuestion = earlier
        let reply = await Self.reply(from: provider, to: ask, within: .seconds(3))
        guard !Task.isCancelled else { return result }
        let fallback = WebLookup.directQuery(question).isEmpty ? WebLookup.directQuery(earlier ?? "") : WebLookup.directQuery(question)
        let written = reply.flatMap(WebLookup.query(inReply:))
        let query = QueryScrubber.clean(written ?? fallback, screenNames: screenNames, userWords: question)
        let queryTook = ContinuousClock.now - start

        // A page the user means ("summarise this page") or named, if it's https.
        var pages = Array(URLGuard.addresses(in: question))
        if question.range(of: #"\bthis\s+(?:page|article|site|website|post|doc|documentation)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil {
            let pid = frontmostPID
            let found = await Task.detached(priority: .userInitiated) { () -> String? in
                var trace = ""
                return AXInspector.pageAddress(frontmostPID: pid, trace: &trace)?.address
            }.value
            if let address = found,
               let url = URL(string: address), URLGuard.allows(url, seenIn: [url]) {
                pages.append(url)
            }
        }
        guard !query.isEmpty || !pages.isEmpty else {
            Log.ask.notice("Lookup: no search words left after cleaning; answering locally")
            return result
        }
        if !query.isEmpty { settings.internet.record(query) }
        pages.prefix(2).forEach { settings.internet.record($0.absoluteString) }

        let searxng = await settings.web.searxngReady()
        let sources = query.isEmpty ? [] : WebSourcePicker.sources(question: question, query: query, reason: reason,
                                                                  searxngAvailable: searxng)
        let outcome = await settings.web.lookUp(query: query, sources: sources, pages: Array(pages.prefix(2)))
        guard !Task.isCancelled else { return result }
        let documents = outcome.documents
        result.passages = await Task.detached(priority: .userInitiated) {
            OnDeviceLanguage.pickPassages(documents, question: question + " " + query)
        }.value
        var seen = Set<URL>()
        let cited = result.passages.filter { seen.insert($0.url).inserted }.prefix(3)
        if !cited.isEmpty {
            result.credit = "Sources: " + cited.map { "[\($0.source.displayName) — \(Self.markdownSafe($0.title))](\($0.url.absoluteString))" }
                .joined(separator: " · ")
        }
        Log.ask.notice("""
            Lookup (\(reason.rawValue, privacy: .public), \(result.needsScreen ? "about the screen" : "text only", privacy: .public)): \
            query \(written == nil ? "fallback" : "written", privacy: .public) in \(String(describing: queryTook), privacy: .public), \
            "\(query, privacy: .private)"; sources \(sources.map(\.rawValue).joined(separator: ","), privacy: .public) \
            (failed: \(outcome.failed.map(\.rawValue).joined(separator: ","), privacy: .public)); \
            \(documents.count, privacy: .public) docs → \(result.passages.count, privacy: .public) passages, \
            \(result.passages.reduce(0) { $0 + $1.text.count }, privacy: .public) chars; \
            \(String(describing: ContinuousClock.now - start), privacy: .public) in all
            """)
        return result
    }

    /// The words a stored user turn asked ("The user said: …" in the prompt text it keeps).
    private static func spokenQuestion(in content: String) -> String {
        guard let range = content.range(of: "The user said: ", options: .backwards) else { return String(content.suffix(200)) }
        return String(content[range.upperBound...].prefix(300))
    }

    private static func markdownSafe(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    /// Looks up the subject a snip's reply opened with (Wikipedia lookups on). Only those
    /// words are sent, and not at all when the close-up shows a face (a person's name is
    /// never sent) or is mostly text (no tour follows). Stored in the snip's memory.
    private func startLookup(_ subject: String) {
        guard let memory = snipMemory, let view = memory.view else { return }
        let reading = memory.text
        snipMemory?.reference = Task { [weak self] in
            if !(await Self.faces(in: view)).isEmpty {
                Log.ask.notice("Lookup: skipped, the snip shows a face")
                return nil
            }
            let share = await PartPlacer.colourfulShare(of: view)
            if let reading, PartsTour.isMostlyText(await TextReader.read(reading, within: .milliseconds(1500)), marked: view.marked,
                                                   colourfulShare: share) {
                Log.ask.notice("Lookup: skipped, the snip is mostly text")
                return nil
            }
            guard !Task.isCancelled, let self, settings.internet.isOn else { return nil }
            settings.internet.record("Wikipedia: \(subject)")
            let start = ContinuousClock.now
            let reference = await WikipediaClient().reference(for: subject)
            Log.ask.notice("""
                Lookup: Wikipedia for \(subject, privacy: .private) → \(reference?.title ?? "nothing", privacy: .private) \
                (\(String(describing: ContinuousClock.now - start), privacy: .public))
                """)
            return reference
        }
    }

    private nonisolated static func faces(in view: SnipView) async -> [(center: Point, width: Double)] {
        await Task.detached(priority: .userInitiated) { FaceFinder.faces(in: view.image) }.value
    }

    /// What "where's / show me …" asks for is clickable on screen now, by (nearly) its name.
    private static func isOnScreen(_ question: String, in elements: [ScreenElement]) -> Bool {
        let targets = InstantAnswer.locateTargets(in: question)
        return !targets.isEmpty && targets.allSatisfy { StepMatcher.find($0, in: elements, minimum: 0.9) != nil }
    }

    /// Shows the plan in the chat and starts walking it.
    private func beginTutorial(_ plan: TutorialPlan, question: String, startedIn: NSRunningApplication?, speak: Bool,
                               display: String, installedName: @escaping (String) -> String?, apps: [String: URL],
                               provider: any LLMProvider, tutorial: TutorialController, continues: Bool = true) async -> Bool {
        if let startedIn, startedIn.processIdentifier != frontmostPID { tutorialReturnApp = startedIn }
        onSetupFinished?()

        if conversation == nil || !chatShown {
            conversation = Conversation()
            snipMemory = nil
            chatShown = true
            onChatOpen?(display)
        } else {
            onChatUserMessage?(display)
        }
        conversation?.append(user: question, assistantSpeech: plan.intro + "\n" + plan.checklist(done: 0))
        if state == .thinking { state = .idle }
        if speak, !plan.intro.isEmpty { speaker.speak(plan.intro) }
        tutorial.isInstalledApp = { installedName($0) != nil }
        tutorial.openApp = { [weak self] name in
            guard let self, let installed = installedName(name) else { return false }
            let ready = await openForTutorial(installed, url: apps[installed]) != nil
            onSetupFinished?()
            return ready
        }
        tutorial.start(plan, goal: question, provider: provider, context: context, blocklist: settings.blocklist,
                       ignoreClickBait: settings.ignoreNotchInCaptures, speak: speak, continues: continues)
        return true
    }

    /// Plans from the app's menus and elements alone when Accessibility describes it
    /// (~1–2 s); otherwise (or if that finds nothing) from the screenshot (~10 s).
    private func planTutorial(_ question: String, capture: ScreenCapture, screenshot: EncodedScreenshot,
                              elements: [ScreenElement], provider: any LLMProvider, holdable: Bool = false) async -> TutorialPlan? {
        let geometry = capture.geometry(imageWidth: screenshot.width, imageHeight: screenshot.height)
        var request = AskRequest(question: question, screenshotJPEG: screenshot.jpeg, screenshotWidth: screenshot.width,
                                 screenshotHeight: screenshot.height, context: context,
                                 elements: PromptElement.list(elements, geometry: geometry, question: question, limit: 25))
        request.planTutorial = true
        request.browser = AppLocator.defaultBrowserName()
        let pid = frontmostPID
        let menus = await Task.detached(priority: .userInitiated) { AXInspector.menuOutline(frontmostPID: pid) }.value
        request.menuOutline = MenuOutline.relevant(menus, to: question, limit: 25)
        // The request names exactly one menu item ("clear history" → History ▸ Clear
        // History…): start at once from the app's own menus; whatever follows (a dialog's
        // button) is planned by the model after the item is chosen.
        if let instant = InstantAnswer.menuPlan(for: question, app: context.appName, outline: menus) {
            Log.ask.notice("Tutorial plan: instant, from the menus (\(instant.steps.count, privacy: .public) steps)")
            return instant
        }
        // A how-to about content ("how do I make this code faster?") is a question: a quick
        // sort (~1 s) spots it. It runs alongside the plan instead of before it, so a real
        // walkthrough doesn't wait for it; a "question" verdict drops the plan. Skipped when
        // asked outright ("show me how…") or when a how-to names an app ("how do I open
        // Safari history"): that is clearly about doing something in it.
        let namesApp = TutorialQuestion.asksForTutorial(question)
            && TutorialQuestion.mentionedApp(in: question, apps: Array(AppLocator.installed().keys)) != nil
        // "Where's / show me X" is about getting to X, never a content question.
        let sorting = !TutorialQuestion.insistsOnWalkthrough(question) && !namesApp
            && !TutorialQuestion.isLocatingRequest(question)
        var sort = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0, context: context)
        sort.sortRequest = true
        let start = ContinuousClock.now
        let planRequest = request
        // Both are child tasks: cancelled with the ask (Esc), and the plan is dropped when
        // this returns early on a "question" verdict.
        async let verdict: String? = sorting
            ? Self.reply(from: provider, to: sort, within: ProviderOperation.classifyRequest.timeout)
            : nil
        async let planned = Self.planSteps(planRequest, menus: menus, provider: provider)
        if sorting {
            let answer = await verdict
            let took = String(describing: ContinuousClock.now - start)
            if let answer, TutorialQuestion.sortedAsAnswer(answer) {
                Log.ask.notice("Sorted as a question in \(took, privacy: .public): answering, no plan")
                return nil
            }
            Log.ask.notice("Sorted as a walkthrough in \(took, privacy: .public)\(answer == nil ? " (no verdict)" : "", privacy: .public)")
            showTutorialPlanning()  // it is a walkthrough: lavender while the steps are planned
        } else {
            Log.ask.notice("Tutorial: no sort needed (\(namesApp ? "a how-to naming an app" : "asked outright", privacy: .public))")
            showTutorialPlanning()
        }
        if holdable { startWalkthroughHold(question: question) }
        let plan = await planned
        walkthroughPlanning = false
        Log.ask.notice("""
            Tutorial plan: \(plan?.steps.count ?? 0, privacy: .public) step(s)\(plan?.app != nil ? " in another app" : "", privacy: .public) \
            in \(String(describing: ContinuousClock.now - start), privacy: .public) (\(menus.count, privacy: .public) menu items)
            """)
        return plan
    }

    /// The model's plan: text-only first when Accessibility describes the app (~1–2 s),
    /// else with the screenshot.
    private nonisolated static func planSteps(_ request: AskRequest, menus: [String], provider: any LLMProvider) async -> TutorialPlan? {
        var plan: TutorialPlan?
        if TutorialPlanning.canUseTextOnly(elements: request.elements.count, menuItems: menus.count) {
            var textOnly = request
            textOnly.screenshotJPEG = Data()
            if let reply = await reply(from: provider, to: textOnly, within: ProviderOperation.planTutorialTextOnly.timeout),
               let parsed = TutorialPlan.parse(reply)?.expandingMenus(using: menus), !parsed.steps.isEmpty || parsed.app != nil {
                plan = parsed
            }
        }
        if plan == nil, !Task.isCancelled,
           let reply = await reply(from: provider, to: request, within: ProviderOperation.planTutorialWithScreenshot.timeout) {
            plan = TutorialPlan.parse(reply)?.expandingMenus(using: menus)
        }
        return plan
    }

    /// Green setup: open the app the task needs and wait until it's in front with its
    /// menus readable (a cold launch takes a few seconds). Then a fresh look at the screen.
    /// Opening or switching apps for a walkthrough: the chat goes along (its checklist).
    @ObservationIgnored private(set) var isOpeningAppForTutorial = false

    private func openForTutorial(_ name: String, url: URL?) async -> (ScreenCapture, EncodedScreenshot, [ScreenElement])? {
        isOpeningAppForTutorial = true
        defer { isOpeningAppForTutorial = false }
        guard let url else {
            show(error: "That needs \(name), which isn't installed.")
            return nil
        }
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL == url }
        onActionStarted?(running ? "switching to \(name)…" : "opening \(name)…")
        Log.ask.notice("Tutorial setup: opening another app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) else {
            show(error: "Couldn't open \(name).")
            return nil
        }
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return nil }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                let pid = app.processIdentifier
                let ready = await Task.detached(priority: .userInitiated) { !AXInspector.menuOutline(frontmostPID: pid, limit: 5).isEmpty }.value
                if ready { break }
            } else {
                app.activate()
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .milliseconds(300))  // the window settles
        onActionDone?("\(running ? "switched to" : "opened") \(app.localizedName ?? name)")
        frontmostPID = app.processIdentifier
        frontmostBundleID = app.bundleIdentifier
        let pid = app.processIdentifier
        let snapshot = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid) }.value
        context = ScreenContext(appName: app.localizedName ?? name, windowTitle: snapshot.windowTitle)
        context.windowFrame = snapshot.windowFrame
        guard let capture = try? await capturer.captureDisplayUnderCursor(excluding: settings.blocklist,
                                                                          ignoreClickBait: settings.ignoreNotchInCaptures),
              let screenshot = try? await ScreenshotEncoder.encodeInBackground(capture.image) else { return nil }
        let elements = await Self.elements(in: capture, frontmostPID: pid)
        return (capture, screenshot, elements)
    }

    // MARK: - Element list

    /// Every listed element costs the local model prompt time (100 took answers to
    /// 11–16 s); the question's matches and open menus are listed first.
    private static let maxListedElements = 40

    /// What Accessibility says is clickable on the captured display (off the main thread).
    private static func elements(in capture: ScreenCapture, frontmostPID pid: pid_t?) async -> [ScreenElement] {
        let frame = capture.displayFrame
        let display = Rect(x: frame.minX, y: capture.primaryDisplayHeight - frame.maxY, width: frame.width, height: frame.height)
        let start = ContinuousClock.now
        let mouse = NSEvent.mouseLocation
        let pointer = Point(x: mouse.x, y: capture.primaryDisplayHeight - mouse.y)
        let elements = await Task.detached(priority: .userInitiated) { () -> [ScreenElement] in
            let front = AXInspector.visibleElements(frontmostPID: pid, display: display)
            guard front.isEmpty, let under = AXInspector.appPID(at: pointer), under != pid else { return front }
            // The app in front has nothing on this display: read the one under the cursor.
            return AXInspector.visibleElements(frontmostPID: under, display: display)
        }.value
        let menus = elements.filter { $0.role == "AXMenuItem" }.count
        Log.ask.notice("""
            Element list: \(elements.count, privacy: .public) clickable (\(menus, privacy: .public) menu items) in \
            \(String(describing: ContinuousClock.now - start), privacy: .public)
            """)
        return elements
    }

    // MARK: - Snip (hold ⌥⌘)

    /// Explains the part of the screen the user circled or boxed, in a chat bubble like
    /// a highlighted-text explanation.
    /// A snip is being answered (true), so thinking stays red; false once it's over.
    @ObservationIgnored var onSnipAnswering: ((Bool) -> Void)?

    private func snip(_ kind: SnipKind, region: Rect, path: [Point]) {
        stopRefining()
        tutorial?.stop(message: nil)
        guard state != .listening, state != .thinking, !isAnswering else { return }
        onSnipAnswering?(true)  // after the guard: a refused snip leaves no red behind
        onInvoked?()  // the chat pops out of the companion where the circling ended
        speaker.stop()
        if conversation != nil {
            closeChat()
            onChatClose?()
        }
        errorResetTask?.cancel()

        let frontmost = NSWorkspace.shared.frontmostApplication
        guard checkCanAsk(frontmost: frontmost) else { return }
        frontmostPID = frontmost?.processIdentifier
        frontmostBundleID = frontmost?.bundleIdentifier
        context = ScreenContext(appName: frontmost?.localizedName)
        let provider = settings.makeProvider()
        self.provider = provider
        Task.detached(priority: .userInitiated) { await provider.warmUp() }
        // Orange (and sendable) from the closed circle: its picture isn't a question yet, but
        // a peel waits for the explanation to start.
        let flow = QuestionFlow(work: .snip, phase: .buildingRequest)
        flow.provider = provider
        // Home is the window under the middle of what was circled (it can be another app's
        // than the front one, or on another display), so "go there!" returns to it.
        let underPID = AXInspector.appWithWindow(at: Point(x: region.x + region.width / 2, y: region.y + region.height / 2))
        if let underPID, underPID != frontmostPID, let app = NSRunningApplication(processIdentifier: underPID) {
            frontmostPID = underPID
            frontmostBundleID = app.bundleIdentifier
            context = ScreenContext(appName: app.localizedName)
            Log.ask.notice("Snip home: the app under the circle, not the front one")
        }
        flow.context = context
        flow.homeBundleID = frontmostBundleID
        flow.homePID = frontmostPID
        currentFlow = flow
        state = .thinking
        Log.ask.notice("Snip: \(kind.rawValue, privacy: .public) \(Int(region.width), privacy: .public)×\(Int(region.height), privacy: .public) pt")
        askTask = Task { await finishSnip(kind, region: region, path: path, flow: flow) }
    }

    private func finishSnip(_ kind: SnipKind, region: Rect, path: [Point], flow: QuestionFlow) async {
        defer { end(flow) }
        let startedAt = ContinuousClock.now
        // Marked files in Finder become the selection, so "combine these" acts on them.
        if flow.homeBundleID == FileAction.requiredFrontmostApp, let pid = flow.homePID {
            await selectMarkedFiles(kind: kind, region: region, path: path, finderPID: pid)
        }
        // The display holding the middle of the region.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = NSPoint(x: region.x + region.width / 2, y: primaryHeight - (region.y + region.height / 2))
        let capture: ScreenCapture
        do {
            capture = try await capturer.captureDisplayUnderCursor(excluding: settings.blocklist, at: center,
                                                                   ignoreClickBait: settings.ignoreNotchInCaptures)
        } catch {
            Log.capture.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            report("Couldn't capture the screen: \(error.localizedDescription)", for: flow)
            return
        }
        guard !Task.isCancelled else { return }
        // The window's title tells the model what app/document the marked thing is in.
        let pid = flow.homePID
        let snapshot = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid) }.value
        flow.context.windowTitle = snapshot.windowTitle
        flow.context.windowFrame = snapshot.windowFrame
        // The window under the circle, not just the app's focused one: from accessibility,
        // which lists only real windows (the window list has a browser's helper windows too).
        let middle = Point(x: region.x + region.width / 2, y: region.y + region.height / 2)
        if let pid, let under = await Task.detached(priority: .userInitiated, operation: { AXInspector.window(at: middle, pid: pid) }).value {
            flow.context.windowTitle = under.title ?? snapshot.windowTitle
            flow.context.windowFrame = under.frame
            readBrowserTab(for: flow, at: middle)
            Log.ask.notice("Snip home: the window under the circle (\(under.title == nil ? "untitled" : "titled", privacy: .public))")
        } else {
            Log.ask.notice("Snip home: no window under the circle; the app's focused one")
        }
        if currentFlow === flow { context = flow.context }
        let view: SnipView
        do {
            view = try SnipRenderer.view(capture, region: region)
        } catch {
            report("Couldn't read that part of the screen.", for: flow)
            return
        }
        let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(view.image) }
        // Printed labels, read on this Mac while the model answers (for the parts tour).
        if flow.jobID == nil {  // sent away: the foreground's memory is the next question's
            snipMemory?.text?.cancel()
            snipMemory?.objects?.cancel()
            snipMemory?.reference?.cancel()
        }
        let text = Task { await TextReader.read(view.image) }
        let objects = Self.findObjects(in: view)
        flow.pendingSnipView = (view, text, objects)
        // No whole-screen context picture: with qwen2.5vl:7b it doubled the wait (8–13 s)
        // and made answers worse; the window title gives the context instead.
        let contextImage: Data? = nil
        await withTaskCancellationHandler {
            await respond(question: "", selectedText: nil, capture: capture, encoding: encoding, startedAt: startedAt,
                          speak: false, display: kind == .circled ? "Explain what I circled" : "Explain what I boxed",
                          snip: kind, snipContext: contextImage, flow: flow)
        } onCancel: {
            text.cancel()
            objects.cancel()
        }
    }

    private func selectMarkedFiles(kind: SnipKind, region: Rect, path: [Point], finderPID pid: pid_t) async {
        let points = SnipArea.samples(kind: kind, region: region, path: path)
        let urls = await Task.detached(priority: .userInitiated) {
            AXInspector.finderItemURLs(at: points, finderPID: pid)
        }.value
        Log.ask.notice("Snip in Finder: \(urls.count, privacy: .public) file(s) under the marked area")
        guard !urls.isEmpty else { return }
        do {
            let selected = try await FinderSelection.select(urls)
            Log.ask.notice("Snip in Finder: selected \(selected, privacy: .public) of \(urls.count, privacy: .public)")
        } catch {
            Log.ask.error("Snip in Finder: couldn't select the marked files: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Answering

    /// The snip a chat started from: follow-ups resend its close-up and context picture.
    @ObservationIgnored private var snipMemory: SnipMemory?

    struct SnipMemory {
        var kind: SnipKind
        var closeUp: EncodedScreenshot
        var context: Data?
        var view: SnipView?
        var text: Task<[TextBox], Never>?
        /// The separate things in the close-up, found on this Mac, for the tour to point at.
        var objects: Task<[FoundObject], Never>?
        /// What the snip shows, looked up on Wikipedia once the reply names its subject
        /// (`startLookup`), for naming the marks. Nil with lookups off.
        var reference: Task<WikiReference?, Never>?
        /// Brought back from the dock ("go there!"): the screen may have changed since, so a
        /// tour first checks the snipped area still looks the same.
        var returnedFromBackground = false
        /// A tour placed while the snip was in the dock: "show me the parts" plays it without
        /// asking the model again (`playReadyTour`).
        var readyTour: [ScreenPointer]?
    }

    /// Whether the chat bubble is on screen. A spoken question doesn't open one until
    /// its answer is in — and not at all when the answer points somewhere: the
    /// companion guides and the answer is spoken, so a chat would just be clutter.
    private var chatShown = false

    /// Shared by ask, explain and chat follow-ups: send to the model (with the open
    /// bubble's memory), stream into the bubble, parse, map, snap, show. A first
    /// message opens a new bubble; anything sent while one is open continues it.
    private func respond(
        question: String,
        selectedText: String?,
        capture: ScreenCapture,
        encoding: Task<EncodedScreenshot, Error>,
        startedAt: ContinuousClock.Instant,
        speak: Bool,
        display: String,
        snip: SnipKind? = nil,
        snipContext: Data? = nil,
        elements: [ScreenElement] = [],
        flow givenFlow: QuestionFlow? = nil,
        autoPeels: Bool = false
    ) async {
        // A walkthrough was just declined: words only — no app opened, nothing pointed at.
        let wordsOnly = answerInWordsOnly
        answerInWordsOnly = false
        if wordsOnly { Log.ask.debug("Answering in words only: the walkthrough was declined") }
        // ⌥⌘ explanations and typed follow-ups have no flow yet: this one's, so they can be peeled too.
        let flow = givenFlow ?? adHocFlow(snip: snip != nil)
        defer { if givenFlow == nil { end(flow) } }
        // Sent to the background before this run existed: the chat, memory and conversation
        // belong to the next question (or nothing), so this one keeps its own.
        let queued = flow.jobID != nil
        let releasedAt = startedAt
        if !queued { answerStartedAt = startedAt }
        var spokeAnything = false
        guard let provider = flow.provider else {
            report("No model is set up for this question.", for: flow)
            return
        }
        let context = flow.context
        flow.phase = .buildingRequest
        if !queued, conversation != nil, !chatShown { conversation = nil }  // an earlier pointing answer: start fresh
        let history = (queued ? flow.conversation : conversation)?.history ?? []
        // Follow-ups in a snip's chat keep looking at what was marked, not a new screenshot.
        let snipFollowUp = history.isEmpty ? nil : (queued ? flow.snipMemory : snipMemory)
        let snip = snip ?? snipFollowUp?.kind
        if queued {
            // nothing of the foreground to set up
        } else if conversation == nil {
            conversation = Conversation()
            snipMemory = nil
            if !speak {  // explain: show the bubble right away, the answer streams into it
                chatShown = true
                // Still undoable by a second tap: the chat opens once that can't happen; a
                // double tap drops it (it used to open the explanation instead of a new chat).
                if isExplainProvisional {
                    explainChat = display
                } else {
                    onChatOpen?(display)
                }
            }
        } else {
            onChatUserMessage?(display)
        }
        let answerID = queued ? UUID() : beginAnswerFlow()
        let run = AnswerRun(id: answerID, question: question, kind: snip == nil ? .answer : .snip,
                            homeBundleID: flow.homeBundleID, homePID: flow.homePID,
                            display: display, conversation: (queued ? flow.conversation : conversation) ?? Conversation())
        run.task = queued ? flow.task : askTask
        run.snipMemory = queued ? flow.snipMemory : snipMemory
        flow.run = run
        if !queued { activeAnswerRun = run }
        defer {
            finishAnswering(answerID)
            if activeAnswerRun?.id == answerID { activeAnswerRun = nil }
        }
        // "… in Safari" while another app is in front: look at Safari's buttons, not the
        // front app's (the first "show me the share button in Safari" looked in the wrong app).
        var elements = elements
        var capture = capture
        var encoding = encoding
        // "Show me the Share button in Safari" with Safari closed or behind: open or switch
        // to it first (green), take a fresh look, then point (blue).
        // Only when the request says so ("in Safari", "open Messages"): an app's name in a
        // sentence is just a word (`TutorialQuestion.locatingApp`).
        var switchedApp = false
        if !wordsOnly, snip == nil, selectedText == nil, history.isEmpty, flow.jobID == nil, TutorialQuestion.isLocatingRequest(question) {
            let apps = AppLocator.installed()
            if let named = TutorialQuestion.locatingApp(in: question, apps: Array(apps.keys)),
               named.caseInsensitiveCompare(context.appName ?? "") != .orderedSame,
               let ready = await openForTutorial(named, url: apps[named]) {
                let screenshot = ready.1
                capture = ready.0
                encoding = Task { screenshot }
                elements = ready.2
                switchedApp = true
                Log.ask.notice("Opened the app the question names, then looking (\(elements.count, privacy: .public) elements)")
            }
            if !switchedApp, TutorialQuestion.mentionedApp(in: question, apps: Array(apps.keys)) != nil,
               TutorialQuestion.locatingApp(in: question, apps: Array(apps.keys)) == nil {
                Log.ask.debug("An app's name in the question, not asked to go there: staying in the app in front")
            }
        }
        // "Where's the Share button?" with exactly one element named Share on screen: point
        // now (~0.1 s), not after the model (~8 s). The model still answers in words; its own
        // pointers are only used when there was no exact, single match.
        var instant: [ScreenPointer]?
        // "Point to October 27th", "today's date": content, not a control. The element list
        // only holds controls, so a pick from it lands on the nearest button ("Today",
        // "View"); the screenshot can see the day.
        let namesContent = InstantAnswer.namesContent(question)
        let targets = !wordsOnly && snip == nil && selectedText == nil && !namesContent ? InstantAnswer.locateTargets(in: question) : []
        if namesContent { Log.ask.notice("Finding content (a date, day or event), not a control: reading the screen") }
        let found = targets.compactMap {
            InstantAnswer.uniqueElement(named: $0, in: elements) ?? InstantAnswer.closeElement(named: $0, in: elements)
        }
        // "Where do I type?": the focused field's caret, exact and instant, before any model —
        // in the app that was in front when asked, never one switched to on the way.
        let pidForCaret = flow.homePID
        let caret = !wordsOnly && snip == nil && selectedText == nil && !switchedApp && InstantAnswer.asksWhereToType(question)
            ? await Task.detached(priority: .userInitiated) { pidForCaret.flatMap { AXInspector.caretRect(pid: $0) } }.value
            : nil
        if let caret {
            let spot = Point(x: caret.minX + 6, y: caret.midY)
            instant = [ScreenPointer(label: "type here", appKit: Point(x: spot.x, y: Double(capture.primaryDisplayHeight) - spot.y),
                                     quartz: spot)]
            Log.ask.notice("Instant pointer: the text caret (where typing goes)")
            flow.kind = .instantPick
            guard await settleQuick(flow) else { return }
            if let instant { onInstantPointer?(instant) }
        } else if !targets.isEmpty, found.count == targets.count {  // every one named exactly once, or none at all
            instant = found.map { element in
                let center = Point(x: element.frame.x + element.frame.width / 2, y: element.frame.y + element.frame.height / 2)
                return ScreenPointer(label: element.label, appKit: Point(x: center.x, y: Double(capture.primaryDisplayHeight) - center.y),
                                     quartz: center)
            }
            Log.ask.notice("Instant pointer: \(found.count, privacy: .public) element(s) named exactly that")
            flow.kind = .instantPick
            guard await settleQuick(flow) else { return }
            if let instant { onInstantPointer?(instant) }
        } else if !wordsOnly, !elements.isEmpty, snip == nil, selectedText == nil, !namesContent,
                  !targets.isEmpty || InstantAnswer.allowsUnnamedPick(question) {
            // Any "where / which / what do I click" question, not only "where's the X": the
            // answer is usually something in the list ("where do I type my message?").
            // Not named exactly: let the model pick from the element list as text (~1.5 s)
            // rather than read the screenshot (~9 s). Nothing fits → the screenshot as before.
            let listed = PromptElement.list(elements, geometry: capture.geometry(imageWidth: Int(capture.displayFrame.width),
                                                                                   imageHeight: Int(capture.displayFrame.height)),
                                            question: question, limit: 80)  // text only: a longer list is cheap
            var pick = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                                  context: context, elements: listed)
            pick.pickElement = true
            let pickStart = ContinuousClock.now
            flow.phase = .elementPick
            let reply = await Self.reply(from: provider, to: pick, within: ProviderOperation.selectElement.timeout)
            flow.phase = .buildingRequest
            let chosen = InstantAnswer.pickedIDs(in: reply ?? "").compactMap { id -> ScreenElement? in
                guard let listing = listed.first(where: { $0.id == id }) else { return nil }
                return elements.first(where: { $0.label == listing.label })
            }
            // "Back and forward": one element for each thing named, or the screenshot. And
            // each must plausibly be the thing named, or the model settled for a neighbour.
            let fits = targets.isEmpty
                ? chosen.allSatisfy { InstantAnswer.unnamedPick($0.label, fits: question) }
                : chosen.count == targets.count && zip(chosen, targets).allSatisfy { InstantAnswer.pick($0.label, fits: $1) }
            if !chosen.isEmpty {
                Log.ask.notice("Pick for \(targets.isEmpty ? "(no named target)" : targets.joined(separator: " + "), privacy: .public): \(chosen.map { "\"\($0.label)\"" }.joined(separator: ", "), privacy: .public)\(fits ? "" : " — doesn't fit, reading the screen instead", privacy: .public)")
            }
            if !chosen.isEmpty, fits {
                instant = chosen.map { element in
                    let center = Point(x: element.frame.x + element.frame.width / 2, y: element.frame.y + element.frame.height / 2)
                    return ScreenPointer(label: element.label, appKit: Point(x: center.x, y: Double(capture.primaryDisplayHeight) - center.y),
                                         quartz: center)
                }
                Log.ask.notice("Picked \(chosen.count, privacy: .public) from the element list in \(String(describing: ContinuousClock.now - pickStart), privacy: .public)")
                flow.kind = .instantPick
                guard await settleQuick(flow) else { return }
                if let instant { onInstantPointer?(instant) }
            } else {
                Log.ask.notice("Nothing among \(listed.count, privacy: .public) listed elements fits (\(String(describing: ContinuousClock.now - pickStart), privacy: .public)); looking at the screen")
            }
        } else if !targets.isEmpty {
            Log.ask.notice("Instant pointer: no single exact match among \(elements.count, privacy: .public) elements; asking the model")
        }
        if flow.jobID == nil { pointedInstantly = instant != nil }
        // Pointed already: the model would only add a sentence (~8 s of the GPU, and the
        // next question waited behind it). Say so ourselves and stop here.
        if let instant {
            encoding.cancel()
            let names = instant.map(\.label).joined(separator: " and ")
            let response = AssistantResponse(speech: "Here's \(names).")
            if speak { speaker.speak(response.speech) }
            if !flow.sentAway { conversation?.append(user: question, assistantSpeech: response.speech) }
            if state == .thinking { state = .idle }
            Log.ask.notice("Answered instantly, without the model")
            onAnswer?(response, instant)
            return
        }
        // "How many days until Christmas?", "what's the date?": worked out here, exactly, in
        // under 0.1 s. The model has no clock and counted 30 days instead of 66 (2026-10-20).
        if snip == nil, selectedText == nil, history.isEmpty, let answer = DateFacts.instantAnswer(question, now: Date()) {
            encoding.cancel()
            let response = AssistantResponse(speech: answer)
            if speak { speaker.speak(response.speech) }
            if !flow.sentAway { conversation?.append(user: question, assistantSpeech: response.speech) }
            if state == .thinking { state = .idle }
            Log.ask.notice("Answered a date question instantly, without the model")
            onAnswer?(response, [])
            return
        }
        // Internet Mode (🌐): online only when the user's words ask (spec decision 3), never
        // for snips (their subject lookup is separate) or pointing. Starts now, alongside the
        // screenshot's encoding.
        let lookupReason = snip == nil && !question.isEmpty && !ImpliedPointer.isLocating(question)
            ? WebLookup.reason(for: question, selectedText: selectedText) : nil
        var webNote: String?
        var webCredit: String?
        var lookup: Task<WebLookupResult, Never>?
        if let lookupReason {
            if settings.internet.isOn {
                let capturedImage = capture
                lookup = Task {
                    await lookUp(question: question, reason: lookupReason, selectedText: selectedText,
                                 capture: capturedImage, history: history, provider: provider)
                }
            } else if lookupReason == .asked {
                webNote = "Internet's off. Switch to 🌐 in the menu bar to look things up."
                Log.ask.notice("Lookup asked for with Internet Mode off: answering locally")
            }
        }
        defer { lookup?.cancel() }
        let reply: String
        let screenshot: EncodedScreenshot
        var request: AskRequest
        var listed: [PromptElement] = []
        do {
            if let snipFollowUp {
                encoding.cancel()
                screenshot = snipFollowUp.closeUp
            } else {
                screenshot = try await encoding.value
            }
            if let snip, history.isEmpty {
                let pending = flow.pendingSnipView
                let memory = SnipMemory(kind: snip, closeUp: screenshot, context: snipContext,
                                        view: pending?.view, text: pending?.text, objects: pending?.objects)
                flow.pendingSnipView = nil
                if flow.jobID == nil {
                    snipMemory?.objects?.cancel()
                    snipMemory = memory
                } else {  // sent away: the foreground's memory is the next question's
                    flow.snipMemory?.objects?.cancel()
                    flow.snipMemory = memory
                }
            }
            // Only "where/how/click…" questions need something to point at; for the rest
            // the list would just slow the local model down. Never for snips.
            if snip == nil, ImpliedPointer.isLocating(question) || !history.isEmpty {
                listed = PromptElement.list(elements, geometry: capture.geometry(imageWidth: screenshot.width, imageHeight: screenshot.height),
                                            question: question, limit: Self.maxListedElements)
            }
            if !elements.isEmpty {
                Log.ask.notice("Element list: offering \(listed.count, privacy: .public) of \(elements.count, privacy: .public)")
            }
            request = AskRequest(
                question: question,
                screenshotJPEG: screenshot.jpeg,
                screenshotWidth: screenshot.width,
                screenshotHeight: screenshot.height,
                context: context,
                selectedText: selectedText,
                history: history,
                snip: snip,
                elements: listed
            )
            request.contextJPEG = snipFollowUp?.context ?? snipContext
            request.askSubject = snip != nil && history.isEmpty && settings.internet.isOn
            if let lookup {
                // What the lookup found within its ~4 s; a question not about the screen is
                // then answered text-only (faster).
                let result = await withTaskCancellationHandler { await lookup.value } onCancel: { lookup.cancel() }
                request.web = result.passages
                if result.passages.isEmpty {
                    webNote = "Couldn't reach the web, so this is from what I know."
                } else {
                    webCredit = result.credit
                    if !result.needsScreen { request.screenshotJPEG = Data(); request.elements = [] }
                }
            }
            // A plain question about the world: the model answers it the same from text, ~6 s
            // sooner (reading the screenshot is most of its time).
            if !request.screenshotJPEG.isEmpty,
               ScreenNeed.isAboutTheWorld(question, selectedText: selectedText, snipped: snip != nil, followUp: !history.isEmpty) {
                request.screenshotJPEG = Data()
                request.elements = []
                Log.ask.notice("About the world, not the screen: asking without the screenshot")
            }
            Log.ask.notice("""
                Asking \(provider.displayName, privacy: .public) with a \(screenshot.width, privacy: .public)x\(screenshot.height, privacy: .public) \
                JPEG (\(screenshot.jpeg.count / 1024, privacy: .public) KB, downscale \(screenshot.downscale, format: .fixed(precision: 3), privacy: .public))
                """)
            var text = ""
            var firstChunkAt: ContinuousClock.Instant?
            var extractor = StreamingSpeechExtractor()
            var sentences = SentenceSplitter()
            var codeFilter = CodeFenceFilter()  // code is shown, never read aloud
            var spokenSoFar = ""
            var isFirstSentence = true
            // Explanations shouldn't open with "The highlighted text refers to…".
            let explaining = selectedText != nil || snip != nil
            let tidy: (String) -> String = { explaining ? ExplanationCleaner.clean($0) : $0 }
            // The chat shows the words as they come, but at most ~12 times a second: redrawing
            // and resizing it for every fragment made the companion stutter while answering.
            var lastPartial = ContinuousClock.now - .seconds(1)
            run.snipMemory = flow.jobID == nil ? snipMemory : flow.snipMemory
            flow.phase = .streaming
            if let jobID = flow.jobID, !flow.joined {
                attach(run, to: flow, appendingQuestion: queued)
                Log.ask.notice("Peel joined: \(jobID.uuidString, privacy: .public)")
            }
            // A first highlight or snip explanation, or a clicked suggestion, goes to the dock by itself when slow.
            if !queued, autoPeels || (history.isEmpty && (selectedText != nil || snip != nil)) { scheduleAutoPeel(flow, run) }
            if backgroundJobs?.entries.contains(where: { $0.job.isWorking && $0.id != flow.jobID }) == true {
                Log.ask.notice("Foreground answer submitted while Ollama is serving a background capsule; Ollama will queue it")
            }
            // A first snip explanation opens with its subject: with lookups on, it's looked up
            // while the rest streams, ready for naming the marks after the answer.
            var lookingUp = !request.askSubject
            for try await chunk in provider.stream(request) {
                if firstChunkAt == nil { firstChunkAt = .now }
                text += chunk
                if !lookingUp, case .foreground = run.destination, let subject = StreamingSubject.subject(in: text) {
                    lookingUp = true
                    startLookup(subject)
                } else if !lookingUp, text.contains("\"speech\"") {
                    lookingUp = true  // no subject before the explanation: nothing to look up
                }
                let newSpeech = extractor.feed(chunk)
                if case .background(let jobID) = run.destination {
                    backgroundJobs?.append(chunk, speech: newSpeech, to: jobID)
                } else if !newSpeech.isEmpty, !Task.isCancelled {
                    spokenSoFar += newSpeech
                    if chatShown, ContinuousClock.now - lastPartial >= .milliseconds(80) {
                        lastPartial = .now
                        onPartialAnswer?(CoordinateScrubber.partial(tidy(spokenSoFar)))
                    }
                    for sentence in sentences.feed(codeFilter.feed(newSpeech)) where speak {
                        speaker.speak(isFirstSentence ? tidy(sentence) : sentence)
                        isFirstSentence = false
                        spokeAnything = true
                    }
                }
            }
            if case .foreground = run.destination, speak, !Task.isCancelled {
                for sentence in sentences.feed(codeFilter.flush()) {
                    speaker.speak(isFirstSentence ? tidy(sentence) : sentence)
                    isFirstSentence = false
                    spokeAnything = true
                }
            }
            if case .foreground = run.destination, speak, !Task.isCancelled, let rest = sentences.flush() {
                speaker.speak(isFirstSentence ? tidy(rest) : rest)
                spokeAnything = true
            }
            // A cancelled stream just ends; don't treat it as an (empty) answer.
            guard !Task.isCancelled else { return }
            reply = text
            let firstChunk = firstChunkAt.map { String(describing: $0 - releasedAt) } ?? "none"
            Log.ask.notice("""
                Reply: first chunk \(firstChunk, privacy: .public) after release, complete after \
                \(String(describing: ContinuousClock.now - releasedAt), privacy: .public), \(reply.count, privacy: .public) characters
                """)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            Log.ask.error("Provider failed: \(error.localizedDescription, privacy: .public)")
            if case .background(let jobID) = run.destination {
                backgroundJobs?.fail(jobID, reason: error.localizedDescription)
                return
            }
            // Sent away but not joined yet: the tile shows it, not the next question's companion.
            if flow.jobID != nil {
                report(error.localizedDescription, for: flow)
                return
            }
            if state == .thinking { state = .idle }
            if chatShown {
                onChatError?(error.localizedDescription)
            } else {
                conversation = nil
                show(error: error.localizedDescription)
            }
            return
        }

        if settings.keepDebugCaptures {
            DebugCaptureStore.saveReply(reply)
        }

        if case .background(let jobID) = run.destination {
            var parsed = ResponseParser.parse(reply, imageWidth: screenshot.width, imageHeight: screenshot.height, elements: listed,
                                             scale: provider.coordinateScale)
            if selectedText != nil || snip != nil { parsed.response.speech = ExplanationCleaner.limited(ExplanationCleaner.clean(parsed.response.speech)) }
            run.conversation.append(user: Prompt.userText(for: request), assistantSpeech: parsed.response.speech,
                                    code: parsed.response.code, language: parsed.response.language)
            var finalText = parsed.response.displayText + (webCredit.map { "\n\n" + $0 } ?? "")
            // A snip in the dock places its tour there too: it waits for "show me the parts".
            var tourReady = false
            if snip != nil, let memory = run.snipMemory, let view = memory.view {
                let named = parsed.response.parts + parsed.response.pointers
                if !named.isEmpty, await !isLabelled(named, memory: memory, view: view), !Task.isCancelled {
                    let placed = await placeTour(named, explanation: parsed.response.speech, memory: memory, view: view,
                                                 provider: provider)
                    if !placed.tour.isEmpty, !Task.isCancelled {
                        var ready = memory
                        ready.readyTour = placed.tour
                        backgroundJobs?.setSnipMemory(ready, for: jobID)
                        if let credit = placed.credit { finalText += "\n\n" + credit }
                        tourReady = true
                    }
                }
            }
            guard !Task.isCancelled else { return }
            settleChat(of: run, finalText: finalText)
            backgroundJobs?.setChatMessages(run.chatMessages, for: jobID)
            if tourReady || (snip != nil && history.isEmpty && !(parsed.response.parts + parsed.response.pointers).isEmpty) {
                backgroundJobs?.setLeadingSuggestion(PeelRule.suggestedPartsPrompt, for: jobID)
            }
            backgroundJobs?.complete(jobID, answer: finalText, conversation: run.conversation)
            return
        }

        var parsed = ResponseParser.parse(reply, imageWidth: screenshot.width, imageHeight: screenshot.height, elements: listed,
                                         scale: provider.coordinateScale)
        if selectedText != nil || snip != nil { parsed.response.speech = ExplanationCleaner.limited(ExplanationCleaner.clean(parsed.response.speech)) }
        // From here a peeled snip keeps its explanation and skips the tour.
        run.explanation = parsed.response.displayText
        let userText = Prompt.userText(for: request), speech = parsed.response.speech
        let code = parsed.response.code, language = parsed.response.language
        run.recordTurn = { $0.append(user: userText, assistantSpeech: speech, code: code, language: language) }
        if snip != nil { flow.phase = .explained }
        // An ⌥⌘ explanation is about the text or area, never about where to click (and a
        // snip's close-up has no screen coordinates anyway).
        // A snip's "where is X?" may come back as pointers: treat them as parts (they're in
        // the close-up's pixels, not the screen's).
        let snipPointers = snip != nil ? parsed.response.pointers : []
        if selectedText != nil || snip != nil, !parsed.response.pointers.isEmpty {
            Log.ask.notice("Explain: ignoring \(parsed.response.pointers.count, privacy: .public) pointer(s) the model added")
            parsed.response.pointers = []
        }
        // Only "where / how / show me / click / open" questions get pointed at; the model
        // sometimes adds a pointer to anything (a corner of the screen for a general question).
        if snip == nil, selectedText == nil, !parsed.response.pointers.isEmpty, wordsOnly || !InstantAnswer.allowsPointing(question) {
            Log.ask.notice("Dropped \(parsed.response.pointers.count, privacy: .public) pointer(s): not a where/how question")
            parsed.response.pointers = []
        }
        // Asked where something is, the answer names a listed element but doesn't point.
        // Only for an explicit where-question, and only a control the user's own words name:
        // otherwise any control the reply mentions got pointed at (the menu bar, 2026-10-14).
        if !wordsOnly, snip == nil, selectedText == nil, parsed.response.pointers.isEmpty, InstantAnswer.allowsPointing(question),
           let implied = ImpliedPointer.find(question: question, speech: parsed.response.speech, elements: listed) {
            if InstantAnswer.unnamedPick(implied.label, fits: question) {
                Log.ask.notice("Pointer taken from the element list: the answer named it without pointing")
                parsed.response.pointers = [implied]
            } else {
                Log.ask.debug("Not pointing at a control only the answer names")
            }
        }
        let geometry = capture.geometry(imageWidth: screenshot.width, imageHeight: screenshot.height)
        let modelPointers = parsed.response.pointers.map { pointer in
            let pixel = Point(x: pointer.x, y: pointer.y)
            return ScreenPointer(
                label: pointer.label,
                appKit: geometry.appKitPoint(fromImagePixel: pixel),
                quartz: geometry.quartzPoint(fromImagePixel: pixel)
            )
        }
        // Pointers on a listed element's exact center came from the app's own data:
        // nothing to snap or double-check.
        let fromList = parsed.response.pointers.map { pointer in listed.contains { $0.isCenter(of: pointer) } }
        let checked = await snap(zip(modelPointers, fromList).filter { !$0.1 }.map(\.0), geometry: geometry)
        var remaining = checked[...]
        let snapped = zip(modelPointers, fromList).map { pointer, listedCenter in
            listedCenter ? (pointer: pointer, confirmed: true) : remaining.popFirst() ?? (pointer: pointer, confirmed: false)
        }
        if fromList.contains(true) {
            Log.ask.notice("\(fromList.filter { $0 }.count, privacy: .public) pointer(s) on a listed element: exact")
        }
        let pointers = instant ?? snapped.map(\.pointer)
        flow.pointed = !pointers.isEmpty
        Log.ask.notice("""
            Parsed reply: fallback=\(parsed.usedFallback, privacy: .public), \
            \(pointers.count, privacy: .public) pointer(s), \(parsed.droppedPointers, privacy: .public) dropped
            """)
        for (pointer, mapped) in zip(parsed.response.pointers, modelPointers) {
            Log.ask.notice("""
                Pointer image px (\(pointer.x, format: .fixed(precision: 0), privacy: .public), \
                \(pointer.y, format: .fixed(precision: 0), privacy: .public)) → screen \(mapped.quartz.description, privacy: .public) \
                (Quartz), \(mapped.appKit.description, privacy: .public) (AppKit)
                """)
        }
        guard !Task.isCancelled else { return }
        // No streamed "speech" field (e.g. plain-text fallback): speak the parsed answer.
        if speak, !spokeAnything {
            var sentences = SentenceSplitter()
            sentences.feed(MessageFormat.spokenText(parsed.response.speech)).forEach(speaker.speak)
            sentences.flush().map(speaker.speak)
        }
        run.conversation.append(user: Prompt.userText(for: request), assistantSpeech: parsed.response.speech,
                                code: parsed.response.code, language: parsed.response.language)
        run.recordTurn = nil  // recorded: a peel from here on must not add it again
        if answerFlowID == answerID { conversation = run.conversation }
        // The answer lives in the chat bubble now; the companion goes back to its arrowhead.
        if state == .thinking || state == .speaking { state = .idle }
        if snip == nil { flow.phase = .explained }  // an answer stays peelable until here
        // Snips: tour the named parts of what was marked — but only when the names aren't
        // already printed in the image (then a tour adds nothing). Where they are is worked
        // out after the answer is shown (`PartPlacer`): on things found on this Mac where it
        // can, else the model's own guesses, so every pill is marked approximate: "~ jupiter".
        var named: [Pointer] = []
        var needsPartsLook = false
        if snip != nil, let memory = snipMemory, let view = memory.view {
            let candidates = parsed.response.parts + snipPointers
            let labelled = await isLabelled(candidates, memory: memory, view: view)
            guard !Task.isCancelled, answerFlowID == answerID else { return }
            // Nothing named at all in a first explanation: a focused second look follows.
            needsPartsLook = !labelled && candidates.isEmpty && history.isEmpty
            if !labelled { named = candidates }
            run.expectsTour = !named.isEmpty || needsPartsLook
        }
        // A reply a pill can say ("Yep, it's on!") opens no chat: the companion says it.
        // Web answers always go to the chat, where their sources can show (spec decision 11).
        if !chatShown, pointers.isEmpty,
           !PillText.fits(parsed.response.speech, code: parsed.response.code) || webCredit != nil || webNote != nil {
            chatShown = true
            onChatOpen?(display)
        }
        onAnswer?(parsed.response, pointers)
        if let webNote { onChatSource?(webNote) }
        if let webCredit { onChatSource?(webCredit) }
        // A snip stays red and spinning until its parts are pointed at; with nothing more to
        // look for, it ends here.
        if snip != nil, named.isEmpty, !needsPartsLook { onSnipAnswering?(false) }

        // Place the named parts and tour them, while the user reads. An explanation that came
        // back without parts (a 7B model often forgets them while writing) is asked once
        // more, just for the parts, first.
        if !named.isEmpty || needsPartsLook, let memory = snipMemory, let view = memory.view, let provider = self.provider {
            defer { if answerFlowID == answerID { onSnipAnswering?(false) } }
            finishAnswering(answerID)
            beginRefining(answerID)
            defer { finishRefining(answerID) }
            if needsPartsLook {
                flow.phase = .partsLook
                var partsRequest = AskRequest(question: parsed.response.speech, screenshotJPEG: memory.closeUp.jpeg,
                                              screenshotWidth: memory.closeUp.width, screenshotHeight: memory.closeUp.height,
                                              context: context)
                partsRequest.listParts = true
                let start = ContinuousClock.now
                guard let reply = await Self.reply(from: provider, to: partsRequest,
                                                   within: ProviderOperation.labelTourParts.timeout), !Task.isCancelled else { return }
                named = ResponseParser.parse(reply, imageWidth: memory.closeUp.width, imageHeight: memory.closeUp.height,
                                             scale: provider.coordinateScale).response.parts
                Log.ask.notice("""
                    Parts look: \(named.count, privacy: .public) named (\(String(describing: ContinuousClock.now - start), privacy: .public)) \
                    in a \(memory.closeUp.width, privacy: .public)×\(memory.closeUp.height, privacy: .public) close-up, marked \
                    \(Int(view.marked.minX), privacy: .public),\(Int(view.marked.minY), privacy: .public)–\
                    \(Int(view.marked.maxX), privacy: .public),\(Int(view.marked.maxY), privacy: .public), scale \
                    \(String(describing: provider.coordinateScale), privacy: .public)
                    """)
            }
            flow.phase = .tourPrep
            let placed = await placeTour(named, explanation: parsed.response.speech, memory: memory, view: view,
                                         provider: provider)
            if let credit = placed.credit { onChatSource?(credit) }
            let tour = placed.tour
            guard !tour.isEmpty, !Task.isCancelled, answerFlowID == answerID else { return }
            if memory.returnedFromBackground, await !stillShows(view) {
                guard !Task.isCancelled, answerFlowID == answerID else { return }
                Log.ask.notice("Parts: the snipped area has changed since it was sent away; no tour")
                onQuickEnding?(PeelRule.movedPill, .capture, true)
                return
            }
            guard !Task.isCancelled, answerFlowID == answerID else { return }
            flow.phase = .tour
            onTour?(tour)
        }

        // Pointers no accessibility element backs up: the triangle is already on its
        // way to the rough spot; take a sharp, zoomed-in look and nudge it if needed.
        guard snapped.contains(where: { !$0.confirmed }), let provider = self.provider else { return }
        // The answer is done: the next question mustn't wait for this.
        finishAnswering(answerID)
        beginRefining(answerID)
        defer { finishRefining(answerID) }
        var refined: [ScreenPointer?] = pointers
        for (index, item) in snapped.enumerated() where !item.confirmed {
            guard !Task.isCancelled else { return }
            switch await refine(item.pointer, question: question, capture: capture, geometry: geometry, provider: provider) {
            case .keep: break
            case .moved(let better): refined[index] = better
            case .rejected: refined[index] = nil
            }
        }
        let kept = refined.compactMap { $0 }
        guard !Task.isCancelled, answerFlowID == answerID, kept != pointers else { return }
        if kept.count < pointers.count {
            Log.ask.notice("Close-up: withdrew \(pointers.count - kept.count, privacy: .public) pointer(s) that matched nothing on screen")
        }
        onPointersRefined?(kept)
    }

    /// Whether a tour of these parts adds nothing: the snip is mostly text (a paragraph,
    /// code), or the names are already printed in it. Only unlabelled figures, diagrams,
    /// drawings and charts get a tour.
    private func isLabelled(_ candidates: [Pointer], memory: SnipMemory, view: SnipView) async -> Bool {
        var text: [TextBox] = []
        if let reading = memory.text { text = await TextReader.read(reading, within: .milliseconds(1500)) }
        let printed = PartsMatcher.match(parts: candidates, speech: "", text: text).verified
        let share = await PartPlacer.colourfulShare(of: view)
        let mostlyText = PartsTour.isMostlyText(text, marked: view.marked, colourfulShare: share)
        let labelled = mostlyText || (!printed.isEmpty && printed.count * 2 >= max(candidates.count, 1))
        Log.ask.notice("""
            Parts: \(candidates.count, privacy: .public) named, \(printed.count, privacy: .public) printed in the image \
            (\(mostlyText ? "text, no tour" : labelled ? "labelled, no tour" : "unlabelled", privacy: .public))
            """)
        return labelled
    }

    /// Where the named parts are (`PartPlacer`) and the tour through them on screen. The
    /// credit line when Wikipedia helped name them. Empty when nothing could be placed.
    private func placeTour(_ named: [Pointer], explanation: String, memory: SnipMemory, view: SnipView,
                           provider: any LLMProvider) async -> (tour: [ScreenPointer], credit: String?) {
        let placing = ContinuousClock.now
        let objects = await memory.objects?.value ?? []
        let reference = await memory.reference?.value
        let placement = await PartPlacer.place(named, explanation: explanation, view: view, objects: objects,
                                               reference: reference, provider: provider)
        let credit = placement.usedReference ? reference?.credit : nil
        guard !placement.stops.isEmpty, !Task.isCancelled else { return ([], credit) }
        let tour = await Self.tourPointers(placement.stops, outlines: placement.outlines, in: view)
        Log.ask.notice("Parts: tour of \(tour.count, privacy: .public) stop(s) by \(placement.method, privacy: .public) starts \(String(describing: ContinuousClock.now - placing), privacy: .public) after the explanation")
        return (tour, credit)
    }

    enum RefineResult {
        /// Leave the rough pointer (nothing to check it against).
        case keep
        case moved(ScreenPointer)
        /// It points at something that isn't what was asked for: take it away.
        case rejected
    }

    /// Checks a point with Accessibility: snaps onto an element whose name matches the
    /// label. `rejected` when Accessibility can see what's there and it's something
    /// else; nil when Accessibility can't see the area (no way to check).
    private func verify(_ point: Point, label: String, geometry: ScreenGeometry) async -> RefineResult? {
        guard AXInspector.isTrusted, !label.isEmpty else { return nil }
        let pid = frontmostPID
        let (candidates, probe) = await Task.detached(priority: .userInitiated) {
            AXInspector.candidates(around: point, frontmostPID: pid)
        }.value
        let decision = Snapper.decide(target: point, label: label, candidates: candidates)
        if decision.reason == .labelMatch {
            return .moved(ScreenPointer(label: label, appKit: geometry.appKitPoint(fromQuartz: decision.point), quartz: decision.point))
        }
        return probe.seesContent ? .rejected : nil
    }

    #if DEBUG
    /// Creates a real, cancellable local Ollama job to inspect capsule runtime behaviour.
    /// The capture goes only to Ollama on this Mac.
    func runDebugCapsuleTest() {
        guard !isBusy, !chatShown else {
            show(error: "Finish or close the current answer before starting a capsule test.")
            return
        }
        guard let jobs = backgroundJobs, jobs.hasRoom else {
            show(error: "There is no free capsule slot for the local test.")
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if settings.blocklist.isBlocked(bundleID: frontmost?.bundleIdentifier) {
            show(error: "ClickBait doesn't look at this app — it's on your blocklist.")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            show(error: "Screen Recording is off. Open Permissions… from the menu bar icon.")
            return
        }

        let question = "For a local capsule runtime check, briefly describe the visible screen content."
        let provider = settings.makeProvider()
        let pid = frontmost.map { Int32($0.processIdentifier) }
        let bundleID = frontmost?.bundleIdentifier
        Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await capturer.captureDisplayUnderCursor(excluding: settings.blocklist,
                                                                           ignoreClickBait: settings.ignoreNotchInCaptures)
                let screenshot = try await ScreenshotEncoder.encodeInBackground(capture.image)
                guard !Task.isCancelled, let jobs = backgroundJobs, jobs.hasRoom else { return }
                let request = AskRequest(question: question, screenshotJPEG: screenshot.jpeg,
                                         screenshotWidth: screenshot.width, screenshotHeight: screenshot.height,
                                         context: ScreenContext(appName: frontmost?.localizedName))
                let job = BackgroundJob(question: question, kind: .answer, homeBundleID: bundleID,
                                       homePID: pid, conversation: Conversation())
                let task = Task { [weak self] in
                    guard let self else { return }
                    await completeDebugCapsuleTest(jobID: job.id, request: request, screenshot: screenshot, provider: provider)
                }
                guard jobs.add(job, task: task) else {
                    task.cancel()
                    return
                }
                var messages = onPeel?(job) ?? []
                if messages.isEmpty { messages = [ChatModel.Message(role: .user, text: question)] }
                jobs.setChatMessages(messages, for: job.id)
                Log.ask.notice("Started DEBUG local capsule runtime check using Ollama")
            } catch {
                guard !Task.isCancelled else { return }
                Log.capture.error("Debug capsule capture failed: \(error.localizedDescription, privacy: .public)")
                show(error: "Couldn't capture the screen for the local capsule test: \(error.localizedDescription)")
            }
        }
    }

    private func completeDebugCapsuleTest(jobID: UUID, request: AskRequest, screenshot: EncodedScreenshot,
                                          provider: OllamaProvider) async {
        guard let jobs = backgroundJobs else { return }
        do {
            var reply = ""
            for try await chunk in provider.stream(request) {
                guard !Task.isCancelled else { return }
                reply += chunk
                jobs.append(chunk, to: jobID)
            }
            guard !Task.isCancelled else { return }
            let parsed = ResponseParser.parse(reply, imageWidth: screenshot.width, imageHeight: screenshot.height,
                                              scale: provider.coordinateScale)
            let answer = parsed.response.displayText
            var conversation = Conversation()
            conversation.append(user: Prompt.userText(for: request), assistantSpeech: parsed.response.speech,
                                code: parsed.response.code, language: parsed.response.language)
            jobs.setChatMessages([
                ChatModel.Message(role: .user, text: request.question),
                ChatModel.Message(role: .assistant, text: answer),
            ], for: jobID)
            jobs.complete(jobID, answer: answer, conversation: conversation)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            jobs.fail(jobID, reason: error.localizedDescription)
        }
    }
    #endif

    /// A close-up look is running after an answer (it can be dropped at any time).
    @ObservationIgnored private var isRefining = false
    @ObservationIgnored private var refiningOwnerID: UUID?

    private func beginAnswerFlow() -> UUID {
        let id = UUID()
        answerFlowID = id
        answeringOwnerID = id
        isAnswering = true
        return id
    }

    private func finishAnswering(_ id: UUID) {
        guard answeringOwnerID == id else { return }
        answeringOwnerID = nil
        isAnswering = false
    }

    private func invalidateAnswerFlow() {
        answerFlowID = nil
        answeringOwnerID = nil
        isAnswering = false
        refiningOwnerID = nil
        isRefining = false
        onSnipAnswering?(false)
    }

    private func beginRefining(_ id: UUID) {
        refiningOwnerID = id
        isRefining = true
    }

    private func finishRefining(_ id: UUID) {
        guard refiningOwnerID == id else { return }
        refiningOwnerID = nil
        isRefining = false
    }

    /// A new question or explanation takes over: drop a close-up still running so the
    /// local model is free at once.
    private func stopRefining() {
        guard isRefining else { return }
        askTask?.cancel()
        invalidateAnswerFlow()
        Log.ask.notice("Close-up dropped: a new question started")
    }

    /// A second look at a pointer on a 2× close-up around it. Nil when the model can't
    /// find the thing there (the rough pointer stays).
    private func refine(_ pointer: ScreenPointer, question: String, capture: ScreenCapture, geometry: ScreenGeometry,
                        provider: any LLMProvider) async -> RefineResult {
        let start = ContinuousClock.now
        let target = pointer.label.isEmpty ? question : pointer.label
        do {
            let closeUp = try CloseUp(capture, around: pointer.quartz)
            let encoded = try await ScreenshotEncoder.encodeInBackground(closeUp.image)
            let request = AskRequest(question: question, screenshotJPEG: encoded.jpeg, screenshotWidth: encoded.width,
                                     screenshotHeight: encoded.height, context: context, locate: target)
            var reply = ""
            for try await chunk in provider.stream(request) { reply += chunk }
            let found = ResponseParser.parse(reply, imageWidth: encoded.width, imageHeight: encoded.height,
                                             scale: provider.coordinateScale).response.pointers.first
            guard let found else {
                // Not in the close-up. Where Accessibility can see the rough spot (and it
                // didn't match before), the guess was wrong; elsewhere keep it.
                let check = await verify(pointer.quartz, label: pointer.label, geometry: geometry)
                Log.ask.notice("Close-up: not found (\(String(describing: ContinuousClock.now - start), privacy: .public)); \(check == nil ? "keeping the rough pointer" : "checked on screen", privacy: .public)")
                return check ?? .keep
            }
            let quartz = closeUp.quartzPoint(fromPixel: found.x * encoded.downscale, found.y * encoded.downscale)
            let shift = ((quartz.x - pointer.quartz.x) * (quartz.x - pointer.quartz.x) + (quartz.y - pointer.quartz.y) * (quartz.y - pointer.quartz.y)).squareRoot()
            // The close-up can "find" something wrong next to a wrong guess: check what's
            // really there before moving the triangle onto it.
            let check = await verify(quartz, label: pointer.label, geometry: geometry)
            let verdict = switch check {
            case .moved: "matches"
            case .rejected: "something else is there, withdrawn"
            default: "unchecked"
            }
            Log.ask.notice("""
                Close-up: \(shift, format: .fixed(precision: 0), privacy: .public) pt away, \(verdict, privacy: .public) \
                (\(String(describing: ContinuousClock.now - start), privacy: .public))
                """)
            return check ?? .moved(ScreenPointer(label: pointer.label, appKit: geometry.appKitPoint(fromQuartz: quartz), quartz: quartz))
        } catch {
            Log.ask.error("Close-up failed: \(error.localizedDescription, privacy: .public)")
            return .keep
        }
    }

    /// Orders that should go to the model as a normal question instead:
    /// "open the File menu" (not an app), or a file order while Finder isn't in front
    /// ("delete this" in a text editor must never touch files).
    private func isUnknownApp(_ command: ActionRequest) -> Bool {
        if command.name == "open_app" { return AppLocator.url(forAppNamed: command.argument ?? "") == nil }
        if case .success(.file) = ActionCatalog.resolve(command, allowedShortcuts: []) {
            return frontmostBundleID != FileAction.requiredFrontmostApp
        }
        return false
    }

    /// A direct order: validate it, run it, confirm out loud. Nothing runs unless it
    /// resolves against the catalog and the user's allowed shortcuts.
    enum ActionOutcome {
        case success(String)
        case failure(String)
        /// Nothing done yet: a question was asked (a reminder's day).
        case asked(String)
    }

    @discardableResult
    /// "Show me that note": Notes in front with the note ClickBait just made (green).
    private func showLastNote(speak: Bool) async -> String? {
        Log.ask.notice("Showing the last note")
        onActionStarted?("opening the note…")
        do {
            guard try await ActionExecutor.showLastNote() else { return nil }
            onActionDone?("opened the note")
            if state == .thinking { state = .idle }
            return "Here it is, in Notes."
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't open the note."
            if speak { speaker.speak(message) }
            show(error: message)
            return message
        }
    }

    private func perform(_ request: ActionRequest, speak: Bool = true) async -> ActionOutcome {
        guard settings.commandsEnabled else { return .failure("Commands are turned off in Settings.") }
        var request = request
        // A day said with a reminder ("…by Friday"), read before a page or selection
        // replaces the words.
        let saidDay = request.name == "add_reminder" ? ReminderText.parse(request.detail ?? "").day : nil
        // "Add this page's URL to my notes": the note is the page (or the selection), not
        // the order's words — which is what the note said before.
        if request.name == "make_note" || request.name == "add_reminder", let reference = NoteReference.find(in: request.detail ?? "") {
            let pid = frontmostPID
            let content: String?
            switch reference {
            case .pageAddress:
                let (page, trace) = await Task.detached(priority: .userInitiated) {
                    var trace = ""
                    return (AXInspector.pageAddress(frontmostPID: pid, trace: &trace), trace)
                }.value
                Log.ask.notice("Page address: \(trace, privacy: .public)")
                content = page.map { NoteReference.noteText(address: $0.address, title: $0.title) }
            case .selection:
                content = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid).selectedText }.value
            case .previous:
                // "Add it to my notes": the answer above in the chat, else the selection.
                if let answer = conversation?.lastAnswer, chatShown {
                    content = NoteReference.content(ofAnswer: answer)
                } else {
                    content = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid).selectedText }.value
                }
            }
            Log.ask.notice("Note is \(String(describing: reference), privacy: .public): \(content == nil ? "not readable" : "read", privacy: .public)")
            guard let content, !content.isEmpty else {
                let message = switch reference {
                case .pageAddress: "I can't see a web page in front."
                case .selection: "Nothing's selected."
                case .previous: "What should the note say?"
                }
                speaker.stop()
                if speak { speaker.speak(message) }
                show(error: message)
                return .failure(message)
            }
            request.detail = content + (saidDay.map { " " + $0.phrase } ?? "")
        }
        // No day said: ask ("when?"), so it lands on a day the Today list shows.
        if request.name == "add_reminder", ReminderText.parse(request.detail ?? "").day == nil {
            return askReminderDay(request, speak: speak)
        }
        switch ActionCatalog.resolve(request, allowedShortcuts: settings.allowedShortcuts) {
        case .failure(let error):
            Log.ask.notice("Action refused: \(request.name, privacy: .public) (\(String(describing: error), privacy: .private))")
            speaker.stop()
            if speak { speaker.speak(error.message) }
            show(error: error.message)
            return .failure(error.message)
        case .success(let action):
            onActionStarted?(Self.workingMessage(for: action))
            do {
                let confirmation = try await ActionExecutor.run(action, blocklist: settings.blocklist,
                                                                ignoreClickBait: settings.ignoreNotchInCaptures)
                Log.ask.notice("Action done: \(request.name, privacy: .public)")
                if let started = answerStartedAt {
                    Log.ask.notice("Command finished \(String(describing: ContinuousClock.now - started), privacy: .public) after release")
                }
                if speak {
                    speaker.speak(confirmation + ".")
                    state = .speaking
                }
                onActionDone?(confirmation)
                return .success(confirmation)
            } catch {
                Log.ask.error("Action failed: \(request.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                speaker.stop()
                if speak { speaker.speak(error.localizedDescription) }
                show(error: error.localizedDescription)
                return .failure(error.localizedDescription)
            }
        }
    }

    private static func workingMessage(for action: ResolvedAction) -> String {
        switch action {
        case .openApp(let name): "Opening \(name)…"
        case .quitApp(let name): "Quitting \(name)…"
        case .setVolume, .setMuted: "Changing the sound…"
        case .setDarkMode: "Switching appearance…"
        case .runShortcut(let name): "Running “\(name)”…"
        case .setWiFi: "Changing Wi-Fi…"
        case .lockScreen: "Locking…"
        case .sleepDisplay: "Turning off the display…"
        case .newFolder: "Making a folder…"
        case .openPlace(let place): "Opening \(place.displayName)…"
        case .makeNote: "Adding a note…"
        case .addReminder: "Adding a reminder…"
        case .media: "…"
        case .screenshot: "Taking a screenshot…"
        case .newFinderWindow: "Opening Finder…"
        case .showDesktop: "Showing the desktop…"
        case .file(let file):
            switch file {
            case .compress: "Compressing…"
            case .merge: "Merging…"
            case .convertImages: "Converting…"
            case .moveIntoNewFolder: "Making a new folder…"
            case .moveTo(let place): "Moving to \(place.displayName)…"
            case .copyTo(let place): "Copying to \(place.displayName)…"
            case .moveToFolder(let name): "Moving into “\(name)”…"
            case .copyToFolder(let name): "Copying into “\(name)”…"
            case .rename: "Renaming…"
            case .moveToTrash: "Moving to the Trash…"
            case .shrink: "Making smaller copies…"
            }
        }
    }

    /// Moves each pointer onto a matching real element nearby, and drops pointers that
    /// don't land on or near anything clickable — the model sometimes points at empty
    /// space for questions that need no clicking. Without Accessibility permission
    /// there's no way to check, so pointers are returned unchanged.
    /// Settles each pointer on the accessibility element it's on or near. `confirmed`
    /// means an element backs it up; the others get a second, zoomed-in look.
    private func snap(_ pointers: [ScreenPointer], geometry: ScreenGeometry) async -> [(pointer: ScreenPointer, confirmed: Bool)] {
        guard AXInspector.isTrusted else {
            Log.ask.notice("Snapping skipped: Accessibility not granted")
            return pointers.map { ($0, false) }
        }
        let pid = frontmostPID
        var snapped: [(pointer: ScreenPointer, confirmed: Bool)] = []
        for pointer in pointers {
            let target = pointer.quartz
            let start = ContinuousClock.now
            let (candidates, probe) = await Task.detached(priority: .userInitiated) {
                AXInspector.candidates(around: target, frontmostPID: pid)
            }.value
            Log.ask.notice("Snap probe: \(probe.description, privacy: .public)")
            let decision = Snapper.decide(target: target, label: pointer.label, candidates: candidates)
            let moved = decision.point != target
            let dx = decision.point.x - target.x, dy = decision.point.y - target.y
            Log.ask.notice("""
                Snap "\(pointer.label, privacy: .private)": \(target.description, privacy: .public) → \
                \(decision.point.description, privacy: .public) (moved \((dx * dx + dy * dy).squareRoot(), format: .fixed(precision: 1), privacy: .public) pt, \
                \(decision.reason.rawValue, privacy: .public), \(candidates.count, privacy: .public) candidates, \
                matched \(decision.candidate?.role ?? "-", privacy: .public) "\(decision.candidate?.label ?? "", privacy: .private)", \
                \(String(describing: ContinuousClock.now - start), privacy: .public))
                """)
            // Nothing to snap to (sidebar rows, canvases, web content…): trust the model's
            // point. Useless pointers are kept away by the prompt and the parser instead.
            guard decision.candidate != nil else {
                Log.ask.notice("Pointer kept as is: \(probe.seesContent ? "no matching element" : "accessibility can't see this area", privacy: .public)")
                snapped.append((pointer, false))
                continue
            }
            let confirmed = Snapper.confirms(decision)
            if !confirmed { Log.ask.notice("Snap inside a whole-window element: not confirmed, the close-up checks it") }
            snapped.append((moved ? ScreenPointer(
                label: pointer.label,
                appKit: geometry.appKitPoint(fromQuartz: decision.point),
                quartz: decision.point
            ) : pointer, confirmed))
        }
        return snapped
    }

    private func cancel(reason: String) {
        guard state == .listening else { return }
        _ = recorder.stop()
        captureTask?.cancel()
        captureTask = nil
        pressedAt = nil
        if currentFlow?.phase == .listening { currentFlow = nil }
        state = .idle
        Log.ask.notice("Cancelled: \(reason, privacy: .public)")
    }

    private func show(error message: String) {
        state = .error(message)
        errorResetTask?.cancel()
        errorResetTask = Task { [weak self] in
            try? await Task.sleep(for: Self.errorDisplayTime)
            guard !Task.isCancelled, let self, case .error = self.state else { return }
            self.state = .idle
        }
    }
}
