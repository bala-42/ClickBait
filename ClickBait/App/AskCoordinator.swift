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
    /// The open chat bubble's memory. Nil when no bubble is open; dropped on close.
    @ObservationIgnored private(set) var conversation: Conversation?
    /// A reply is being fetched for the chat (blocks a second send).
    @ObservationIgnored private(set) var isAnswering = false
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
            isAnswering = false
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
        if state == .speaking || state == .thinking { state = .idle }
    }

    // MARK: - Chat

    /// The chat bubble was closed (✕ or Escape): its memory goes with it.
    func closeChat() {
        tutorial?.stop(message: nil)
        guard conversation != nil, chatShown else { return }
        speaker.stop()
        askTask?.cancel()
        askTask = nil
        conversation = nil
        chatShown = false
        isAnswering = false
        if state == .thinking || state == .speaking { state = .idle }
        Log.ask.notice("Chat closed")
    }

    /// A message typed into the open chat bubble. Replies to typed messages are text only.
    func sendTyped(_ text: String) {
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
                isAnswering = true
                askTask = Task {
                    defer { isAnswering = false }
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
            isAnswering = true
            askTask = Task {
                defer { isAnswering = false }
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
                isAnswering = true
                defer { isAnswering = false }
                switch order {
                case .ready(let action): onChatReply?(await handleProposal(action, request: proposal, speak: false))
                case .failed(let reason): onChatError?(reason)
                }
                return
            }
            let snapshot = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid) }.value
            context.windowTitle = snapshot.windowTitle
            context.focusedElement = snapshot.focusedElement
            let capture: ScreenCapture
            do {
                capture = try await capturer.captureDisplayUnderCursor(excluding: blocklist)
            } catch {
                onChatError?("Couldn't capture the screen: \(error.localizedDescription)")
                return
            }
            let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(capture.image) }
            let elements = await Self.elements(in: capture, frontmostPID: pid)
            if await startTutorial(question: text, capture: capture, encoding: encoding, elements: elements,
                                   speak: false, display: text) { return }
            await respond(question: text, selectedText: nil, capture: capture, encoding: encoding, startedAt: startedAt,
                          speak: false, display: text, elements: elements)
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
            isAnswering = false
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
        stopRefining()
        tutorial?.stop(message: nil)  // a new question ends a tutorial
        guard state != .listening, state != .thinking, !isAnswering else { return }
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
        case .notDownloaded, .downloading:
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
        captureTask = Task { [capturer] in try await capturer.captureDisplayUnderCursor(excluding: blocklist) }
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
        state = .listening
        Log.ask.notice("Listening (frontmost: \(frontmost?.bundleIdentifier ?? "none", privacy: .private))")
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
        if settings.provider == .anthropic, (KeychainStore.read(.anthropicAPIKey) ?? "").isEmpty {
            show(error: LLMError.missingAPIKey.localizedDescription)
            return false
        }
        return true
    }

    private func finish() async {
        guard state == .listening, let pressedAt else { return }
        let held = ContinuousClock.now - pressedAt
        guard held >= Self.minimumHold else {
            cancel(reason: "hold was too short")
            return
        }

        let releasedAt = ContinuousClock.now
        try? await Task.sleep(for: Self.releaseTail)
        guard state == .listening else { return }  // cancelled meanwhile
        let samples = recorder.stop()
        answerStartedAt = releasedAt
        state = .thinking
        self.pressedAt = nil

        let capture: ScreenCapture
        do {
            guard let captureTask else { throw CancellationError() }
            capture = try await captureTask.value
        } catch {
            Log.capture.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            show(error: "Couldn't capture the screen: \(error.localizedDescription)")
            return
        }
        captureTask = nil

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
            context.windowTitle = snapshot.windowTitle
            context.focusedElement = snapshot.focusedElement
        }

        // Downscale and list what's clickable while Whisper runs.
        let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(capture.image) }
        let pid = frontmostPID
        let elementsTask = Task { await Self.elements(in: capture, frontmostPID: pid) }

        guard !audio.isSilent else {
            show(error: "I didn't hear anything. Check the microphone, hold ⌃⌥ and try again.")
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
            show(error: "Couldn't understand the recording: \(error.localizedDescription)")
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
            show(error: "I didn't catch that. Hold Control+Option and try again.")
            return
        }
        // A day answers a reminder's "when?"; "cancel" drops it; anything else replaces it.
        if pendingReminder != nil {
            if let day = ReminderDay.parse(transcript) {
                encoding.cancel()
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
                await resolvePending(answer)
                return
            }
            dropPending()
        }
        onTranscript?(transcript)

        if NoteReference.asksToSeeNote(transcript), ActionExecutor.lastNoteID.withLock({ $0 }) != nil {
            encoding.cancel()
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
            _ = await perform(command)  // the outcome is already shown and spoken
            return
        }

        // An order in other words: ask the model which action it is (text only, ~1 s).
        let understood = await understandOrder(transcript)
        guard !Task.isCancelled else { return }  // Esc while checking
        if let (order, proposal) = understood {
            encoding.cancel()
            let message: String
            switch order {
            case .ready(let action): message = await handleProposal(action, request: proposal, speak: true)
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
                               speak: true, display: transcript) { return }

        // With a chat open, a spoken question is a follow-up in it.
        await respond(question: transcript, selectedText: nil, capture: capture, encoding: encoding, startedAt: releasedAt,
                      speak: true, display: transcript, elements: elements)
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
        guard let (selected, method) = await SelectionReader.read(frontmostPID: pid, accessibilitySelection: snapshot.selectedText)
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
        context.focusedElement = snapshot.focusedElement
        Log.ask.notice("Explain: \(selected.count, privacy: .public) characters selected via \(method.rawValue, privacy: .public)")
        if isExplainProvisional { pendingExcerpt = selected } else { onExplaining?(selected) }

        let capture: ScreenCapture
        do {
            capture = try await capturer.captureDisplayUnderCursor(excluding: settings.blocklist)
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

    /// An order the rules didn't catch but the model understood: safe actions run now;
    /// ones that move, rename, bin or quit something are asked about first.
    /// Returns what to show in the chat: the question asked, or the result.
    @discardableResult
    private func handleProposal(_ action: ResolvedAction, request proposal: ActionRequest, speak: Bool) async -> String {
        if ActionCatalog.needsConfirmation(action) {
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
            Log.ask.notice("Understood order \(proposal.name, privacy: .public): asking first")
            if speak { speaker.speak(question) }
            if state == .thinking { state = .idle }
            onConfirmRequest?(question)
            return question
        }
        Log.ask.notice("Understood order \(proposal.name, privacy: .public): running")
        switch await perform(proposal, speak: speak) {
        case .success(let confirmation): return confirmation + "."
        case .failure(let message): return message
        case .asked(let question): return question
        }
    }

    /// The whole reply to `request`, or nil if it fails or takes longer than `limit`.
    private nonisolated static func reply(from provider: any LLMProvider, to request: AskRequest, within limit: Duration) async -> String? {
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

    /// For orders the rules don't recognise ("stash these in my documents"): a quick,
    /// text-only request asking which known action it is. Nil if none (or no answer in
    /// time); the result still has to pass the catalog and the Finder check.
    enum UnderstoodOrder {
        case ready(ResolvedAction)
        /// Understood, but can't be done (the reason, for the user).
        case failed(String)
    }

    private func understandOrder(_ text: String) async -> (UnderstoodOrder, ActionRequest)? {
        guard settings.commandsEnabled, CommandParser.looksLikeOrder(text), let provider else { return nil }
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
        let reply = await Self.reply(from: provider, to: request, within: .seconds(8))
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
                               elements: [ScreenElement], speak: Bool, display: String) async -> Bool {
        // Lavender while planning, once an app was opened for the walkthrough (green →
        // lavender, not green → idle blue → lavender). Dropped again if no tutorial starts.
        tutorialPlanningShown = false
        defer {
            if tutorialPlanningShown, !(tutorial?.isActive ?? false) { onTutorialPlanning?(false) }
            tutorialPlanningShown = false
        }
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
                let pid = frontmostPID
                let path = await Task.detached(priority: .userInitiated) { AXInspector.menuPath(to: target, frontmostPID: pid) }.value
                findingHidden = (path?.count ?? 0) >= 2
            }
        }
        guard asking || ordering || visiting || toSystemSettings || findingHidden, let provider, let tutorial else { return false }
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
            // Ask before switching apps: no plan yet (it's made in that app), so a no gets a
            // written answer instead.
            guard await offerWalkthrough(opening: named) else { return false }
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
            plan = await planTutorial(question, capture: capture, screenshot: screenshot, elements: elements, provider: provider)?
                .separatingSetup(frontmostApp: context.appName, isInstalledApp: { installedName($0) != nil })
            // The plan says it happens in another app: ask, then open it (green) and plan again there.
            guard let other = plan?.app.flatMap(installedName), let url = apps[other] else { break }
            if !offered {
                offered = true
                guard await offerWalkthrough(opening: other) else { return false }
            }
            guard let ready = await openForTutorial(other, url: url) else { return false }
            showTutorialPlanning()
            (capture, screenshot, elements) = ready
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

    /// Faces in a snip's close-up, found off the main thread.
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
        tutorial.start(plan, goal: question, provider: provider, context: context, blocklist: settings.blocklist, speak: speak,
                       continues: continues)
        return true
    }

    /// Plans from the app's menus and elements alone when Accessibility describes it
    /// (~1–2 s); otherwise (or if that finds nothing) from the screenshot (~10 s).
    private func planTutorial(_ question: String, capture: ScreenCapture, screenshot: EncodedScreenshot,
                              elements: [ScreenElement], provider: any LLMProvider) async -> TutorialPlan? {
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
        async let verdict: String? = sorting ? Self.reply(from: provider, to: sort, within: .seconds(3)) : nil
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
        let plan = await planned
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
            if let reply = await reply(from: provider, to: textOnly, within: .seconds(15)),
               let parsed = TutorialPlan.parse(reply)?.expandingMenus(using: menus), !parsed.steps.isEmpty || parsed.app != nil {
                plan = parsed
            }
        }
        if plan == nil, !Task.isCancelled, let reply = await reply(from: provider, to: request, within: .seconds(25)) {
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
        guard let capture = try? await capturer.captureDisplayUnderCursor(excluding: settings.blocklist),
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
        state = .thinking
        Log.ask.notice("Snip: \(kind.rawValue, privacy: .public) \(Int(region.width), privacy: .public)×\(Int(region.height), privacy: .public) pt")
        askTask = Task { await finishSnip(kind, region: region, path: path) }
    }

    private func finishSnip(_ kind: SnipKind, region: Rect, path: [Point]) async {
        let startedAt = ContinuousClock.now
        // Marked files in Finder become the selection, so "combine these" acts on them.
        if frontmostBundleID == FileAction.requiredFrontmostApp, let pid = frontmostPID {
            await selectMarkedFiles(kind: kind, region: region, path: path, finderPID: pid)
        }
        // The display holding the middle of the region.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = NSPoint(x: region.x + region.width / 2, y: primaryHeight - (region.y + region.height / 2))
        let capture: ScreenCapture
        do {
            capture = try await capturer.captureDisplayUnderCursor(excluding: settings.blocklist, at: center)
        } catch {
            Log.capture.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            show(error: "Couldn't capture the screen: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }
        // The window's title tells the model what app/document the marked thing is in.
        let pid = frontmostPID
        let snapshot = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid) }.value
        context.windowTitle = snapshot.windowTitle
        let view: SnipView
        do {
            view = try SnipRenderer.view(capture, region: region)
        } catch {
            show(error: "Couldn't read that part of the screen.")
            return
        }
        let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(view.image) }
        // Printed labels, read on this Mac while the model answers (for the parts tour).
        pendingSnipView = (view, Task { await TextReader.read(view.image) })
        // No whole-screen context picture: with qwen2.5vl:7b it doubled the wait (8–13 s)
        // and made answers worse; the window title gives the context instead.
        let contextImage: Data? = nil
        await respond(question: "", selectedText: nil, capture: capture, encoding: encoding, startedAt: startedAt,
                      speak: false, display: kind == .circled ? "Explain what I circled" : "Explain what I boxed",
                      snip: kind, snipContext: contextImage)
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
    /// The close-up's geometry and text recognition, handed from `finishSnip` to `respond`.
    @ObservationIgnored private var pendingSnipView: (view: SnipView, text: Task<[TextBox], Never>)?

    struct SnipMemory {
        var kind: SnipKind
        var closeUp: EncodedScreenshot
        var context: Data?
        var view: SnipView?
        var text: Task<[TextBox], Never>?
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
        elements: [ScreenElement] = []
    ) async {
        let releasedAt = startedAt
        answerStartedAt = startedAt
        var spokeAnything = false
        guard let provider else { return }
        if conversation != nil, !chatShown { conversation = nil }  // an earlier pointing answer: start fresh
        let history = conversation?.history ?? []
        // Follow-ups in a snip's chat keep looking at what was marked, not a new screenshot.
        let snipFollowUp = history.isEmpty ? nil : snipMemory
        let snip = snip ?? snipFollowUp?.kind
        if conversation == nil {
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
        isAnswering = true
        defer { isAnswering = false }
        // "… in Safari" while another app is in front: look at Safari's buttons, not the
        // front app's (the first "show me the share button in Safari" looked in the wrong app).
        var elements = elements
        var capture = capture
        var encoding = encoding
        // "Show me the Share button in Safari" with Safari closed or behind: open or switch
        // to it first (green), take a fresh look, then point (blue).
        if snip == nil, selectedText == nil, history.isEmpty, TutorialQuestion.isLocatingRequest(question) {
            let apps = AppLocator.installed()
            if let named = TutorialQuestion.taskApp(in: question, apps: Array(apps.keys)),
               named.caseInsensitiveCompare(context.appName ?? "") != .orderedSame,
               let ready = await openForTutorial(named, url: apps[named]) {
                let screenshot = ready.1
                capture = ready.0
                encoding = Task { screenshot }
                elements = ready.2
                Log.ask.notice("Opened the app the question names, then looking (\(elements.count, privacy: .public) elements)")
            }
        }
        // "Where's the Share button?" with exactly one element named Share on screen: point
        // now (~0.1 s), not after the model (~8 s). The model still answers in words; its own
        // pointers are only used when there was no exact, single match.
        var instant: [ScreenPointer]?
        let targets = snip == nil && selectedText == nil ? InstantAnswer.locateTargets(in: question) : []
        let found = targets.compactMap {
            InstantAnswer.uniqueElement(named: $0, in: elements) ?? InstantAnswer.closeElement(named: $0, in: elements)
        }
        if !targets.isEmpty, found.count == targets.count {  // every one named exactly once, or none at all
            instant = found.map { element in
                let center = Point(x: element.frame.x + element.frame.width / 2, y: element.frame.y + element.frame.height / 2)
                return ScreenPointer(label: element.label, appKit: Point(x: center.x, y: Double(capture.primaryDisplayHeight) - center.y),
                                     quartz: center)
            }
            Log.ask.notice("Instant pointer: \(found.count, privacy: .public) element(s) named exactly that")
            onInstantPointer?(instant!)
        } else if !elements.isEmpty, snip == nil, selectedText == nil,
                  targets.count == 1 || (targets.isEmpty && ImpliedPointer.isLocating(question)
                                         && !ImpliedPointer.normalized(question).hasPrefix("show me how")) {
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
            if let reply = await Self.reply(from: provider, to: pick, within: .seconds(5)), let id = InstantAnswer.pickedID(in: reply),
               let chosen = listed.first(where: { $0.id == id }),
               let element = elements.first(where: { $0.label == chosen.label }) {
                let center = Point(x: element.frame.x + element.frame.width / 2, y: element.frame.y + element.frame.height / 2)
                instant = [ScreenPointer(label: element.label, appKit: Point(x: center.x, y: Double(capture.primaryDisplayHeight) - center.y),
                                         quartz: center)]
                Log.ask.notice("Picked from the element list in \(String(describing: ContinuousClock.now - pickStart), privacy: .public)")
                onInstantPointer?(instant!)
            } else {
                Log.ask.notice("Nothing among \(listed.count, privacy: .public) listed elements fits (\(String(describing: ContinuousClock.now - pickStart), privacy: .public)); looking at the screen")
            }
        } else if !targets.isEmpty {
            Log.ask.notice("Instant pointer: no single exact match among \(elements.count, privacy: .public) elements; asking the model")
        }
        pointedInstantly = instant != nil
        // Pointed already: the model would only add a sentence (~8 s of the GPU, and the
        // next question waited behind it). Say so ourselves and stop here.
        if let instant {
            encoding.cancel()
            let names = instant.map(\.label).joined(separator: " and ")
            let response = AssistantResponse(speech: "Here's \(names).")
            if speak { speaker.speak(response.speech) }
            conversation?.append(user: question, assistantSpeech: response.speech)
            if state == .thinking { state = .idle }
            Log.ask.notice("Answered instantly, without the model")
            onAnswer?(response, instant)
            return
        }
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
                snipMemory = SnipMemory(kind: snip, closeUp: screenshot, context: snipContext,
                                        view: pendingSnipView?.view, text: pendingSnipView?.text)
                pendingSnipView = nil
            }
            // Only "where/how/click…" questions need something to point at; for the rest
            // the list would just slow the local model down. Never for snips.
            if snip == nil, ImpliedPointer.isLocating(question) || conversation?.isEmpty == false {
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
            for try await chunk in provider.stream(request) {
                if firstChunkAt == nil { firstChunkAt = .now }
                text += chunk
                let newSpeech = extractor.feed(chunk)
                if !newSpeech.isEmpty, !Task.isCancelled {
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
            if speak, !Task.isCancelled {
                for sentence in sentences.feed(codeFilter.flush()) {
                    speaker.speak(isFirstSentence ? tidy(sentence) : sentence)
                    isFirstSentence = false
                    spokeAnything = true
                }
            }
            if speak, !Task.isCancelled, let rest = sentences.flush() {
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

        var parsed = ResponseParser.parse(reply, imageWidth: screenshot.width, imageHeight: screenshot.height, elements: listed,
                                         scale: provider.coordinateScale)
        if selectedText != nil || snip != nil { parsed.response.speech = ExplanationCleaner.clean(parsed.response.speech) }
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
        if snip == nil, selectedText == nil, !parsed.response.pointers.isEmpty, !ImpliedPointer.isLocating(question) {
            Log.ask.notice("Dropped \(parsed.response.pointers.count, privacy: .public) pointer(s): not a where/how question")
            parsed.response.pointers = []
        }
        // Asked where something is, the answer names a listed element but doesn't point.
        if snip == nil, selectedText == nil, parsed.response.pointers.isEmpty,
           let implied = ImpliedPointer.find(question: question, speech: parsed.response.speech, elements: listed) {
            Log.ask.notice("Pointer taken from the element list: the answer named it without pointing")
            parsed.response.pointers = [implied]
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
        conversation?.append(user: Prompt.userText(for: request), assistantSpeech: parsed.response.speech,
                             code: parsed.response.code, language: parsed.response.language)
        // The answer lives in the chat bubble now; the companion goes back to its arrowhead.
        if state == .thinking || state == .speaking { state = .idle }
        // Snips: tour the named parts of what was marked — but only when the names aren't
        // already printed in the image (then a tour adds nothing). Positions come from the
        // model alone, right only about half the time on such images, so every pill is
        // marked approximate: "~ supraspinatus".
        var tour: [ScreenPointer] = []
        var needsPartsLook = false
        if snip != nil, let memory = snipMemory, let view = memory.view {
            var text: [TextBox] = []
            if let reading = memory.text { text = await TextReader.read(reading, within: .milliseconds(1500)) }
            let candidates = parsed.response.parts + snipPointers
            let printed = PartsMatcher.match(parts: candidates, speech: "", text: text).verified
            // Labelled figures (names already printed) and plain text (a paragraph, code)
            // get no tour: only unlabelled figures, diagrams, drawings and charts do.
            let mostlyText = PartsTour.isMostlyText(text, marked: view.marked)
            let labelled = mostlyText || (!printed.isEmpty && printed.count * 2 >= max(candidates.count, 1))
            // Nothing named at all in a first explanation: a focused second look follows.
            needsPartsLook = !labelled && candidates.isEmpty && history.isEmpty
            if !labelled {
                let faces = await Self.faces(in: view)
                let stops = PartsTour.stops(FaceSnapping.snap(candidates, to: faces), marked: view.marked)
                tour = stops.map { view.screenPointer(Pointer(x: $0.x, y: $0.y, label: "~ " + $0.label.lowercased())) }
            }
            Log.ask.notice("""
                Parts: \(candidates.count, privacy: .public) named, \(printed.count, privacy: .public) printed in the image \
                (\(mostlyText ? "text, no tour" : labelled ? "labelled, no tour" : "unlabelled", privacy: .public)); touring \(tour.count, privacy: .public) (~)
                """)
        }
        // A reply a pill can say ("Yep, it's on!") opens no chat: the companion says it.
        if !chatShown, pointers.isEmpty, !PillText.fits(parsed.response.speech, code: parsed.response.code) {
            chatShown = true
            onChatOpen?(display)
        }
        onAnswer?(parsed.response, pointers)
        // A snip stays red and spinning until its parts are pointed at; with nothing more to
        // look for, it ends here.
        if snip != nil, !tour.isEmpty || !needsPartsLook { onSnipAnswering?(false) }
        if !tour.isEmpty { onTour?(tour) }

        // The explanation came back without parts (a 7B model often forgets them while
        // writing): ask once more, just for the parts, while the user reads.
        if needsPartsLook, let memory = snipMemory, let view = memory.view, let provider = self.provider {
            defer { onSnipAnswering?(false) }  // red ends with the look, tour or not
            isAnswering = false
            isRefining = true
            defer { isRefining = false }
            var partsRequest = AskRequest(question: parsed.response.speech, screenshotJPEG: memory.closeUp.jpeg,
                                          screenshotWidth: memory.closeUp.width, screenshotHeight: memory.closeUp.height,
                                          context: context)
            partsRequest.listParts = true
            let start = ContinuousClock.now
            guard let reply = await Self.reply(from: provider, to: partsRequest, within: .seconds(20)), !Task.isCancelled else { return }
            let parts = ResponseParser.parse(reply, imageWidth: memory.closeUp.width, imageHeight: memory.closeUp.height,
                                             scale: provider.coordinateScale).response.parts
            let faces = await Self.faces(in: view)
            let stops = PartsTour.stops(FaceSnapping.snap(parts, to: faces), marked: view.marked)
            if !faces.isEmpty { Log.ask.notice("Parts look: \(faces.count, privacy: .public) face(s) found; people placed on them") }
            let positions = parts.prefix(4).map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")
            Log.ask.notice("""
                Parts look: \(parts.count, privacy: .public) named, touring \(stops.count, privacy: .public) \
                (\(String(describing: ContinuousClock.now - start), privacy: .public)); parts at \(positions, privacy: .public) \
                in a \(memory.closeUp.width, privacy: .public)×\(memory.closeUp.height, privacy: .public) close-up, marked \
                \(Int(view.marked.minX), privacy: .public),\(Int(view.marked.minY), privacy: .public)–\
                \(Int(view.marked.maxX), privacy: .public),\(Int(view.marked.maxY), privacy: .public), scale \
                \(String(describing: provider.coordinateScale), privacy: .public)
                """)
            guard !stops.isEmpty else { return }
            onTour?(stops.map { view.screenPointer(Pointer(x: $0.x, y: $0.y, label: "~ " + $0.label.lowercased())) })
        }

        // Pointers no accessibility element backs up: the triangle is already on its
        // way to the rough spot; take a sharp, zoomed-in look and nudge it if needed.
        guard snapped.contains(where: { !$0.confirmed }), let provider = self.provider else { return }
        // The answer is done: the next question mustn't wait for this.
        isAnswering = false
        isRefining = true
        defer { isRefining = false }
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
        guard !Task.isCancelled, kept != pointers else { return }
        if kept.count < pointers.count {
            Log.ask.notice("Close-up: withdrew \(pointers.count - kept.count, privacy: .public) pointer(s) that matched nothing on screen")
        }
        onPointersRefined?(kept)
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

    /// A close-up look is running after an answer (it can be dropped at any time).
    @ObservationIgnored private var isRefining = false

    /// A new question or explanation takes over: drop a close-up still running so the
    /// local model is free at once.
    private func stopRefining() {
        guard isRefining else { return }
        askTask?.cancel()
        isRefining = false
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
                let confirmation = try await ActionExecutor.run(action, blocklist: settings.blocklist)
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
            snapped.append((moved ? ScreenPointer(
                label: pointer.label,
                appKit: geometry.appKitPoint(fromQuartz: decision.point),
                quartz: decision.point
            ) : pointer, true))
        }
        return snapped
    }

    private func cancel(reason: String) {
        guard state == .listening else { return }
        _ = recorder.stop()
        captureTask?.cancel()
        captureTask = nil
        pressedAt = nil
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
