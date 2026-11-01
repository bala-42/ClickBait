import AppKit
import AVFoundation
import ClickBaitCore
import Observation

// The chat bubble, and follow-ups from a done card.
extension AskCoordinator {
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
        // "remember …" / "forget …": the user's own facts (`Memory`), answered in the chat.
        if let command = Memory.command(in: text) {
            onChatUserMessage?(text)
            let reply = MemoryStore.shared.reply(to: command)
            Log.ask.notice("Memory (typed): \(reply.ok ? "done" : "not done", privacy: .public)")
            if reply.ok { onChatReply?(reply.message) } else { onChatError?(reply.message) }
            return
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
            // "Find the march invoice" is smart search (in `respond`): not an order or a walkthrough.
            let searching = SmartSearch.request(in: text) != nil
            if !searching, let (order, proposal) = await understandOrder(text) {
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
            if !searching, await startTutorial(question: text, capture: capture, encoding: encoding, elements: elements,
                                               speak: false, display: text) { return }
            // Highlighted code is what "fix this" means; other selections would turn pointing off.
            let highlighted = snapshot.selectedText.flatMap { CodeAnswer.looksLikeCode($0) && !ImpliedPointer.isLocating(text) ? $0 : nil }
            await respond(question: text, selectedText: highlighted, capture: capture, encoding: encoding, startedAt: startedAt,
                          speak: false, display: text, elements: elements, autoPeels: autoPeels, highlightIsContext: true)
        }
    }

    /// Escape while listening or thinking abandons the question.
    /// ⌥⌘ + right-click or double-tap ⌥⌘: an empty chat to type the first question into. Sent messages go
    /// through `sendTyped` like any typed follow-up (screen, pointing, actions).
    func startTypedChat(trigger: String = "⌥⌘ right-click") {
        onInvoked?()
        nextTypedIsDetailed = false  // only ever for the "tell me more" it was set for
        if snipper.isActive { snipper.cancel() }
        let flags = NSEvent.modifierFlags
        if flags.contains(.option), flags.contains(.command) { ignoreExplainRelease = true }
        // Busy answering: that goes to the dock, and a fresh chat opens (user's rule, 2026-10-24).
        if state == .thinking || isAnswering {
            guard acceptsNewQuestion(.explain), state != .thinking, !isAnswering else { return }
        } else if conversation != nil, chatShown {
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

    func begin() {
        guard !isCardRecording else {
            Log.ask.notice("⌃⌥ ignored: a card's voice panel is recording")
            return
        }
        guard !isDictating else {
            Log.ask.notice("⌃⌥ ignored: dictating")
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
        // Its tab now, where it was asked: read later, the user may have moved on (and a
        // move-on is what sends it to the dock).
        readBrowserTab(for: flow, at: nil)
        currentFlow = flow
        state = .listening
        Log.ask.notice("Listening (frontmost: \(frontmost?.bundleIdentifier ?? "none", privacy: .private))")
    }

    /// In Chrome or Safari: asks the browser which tab is showing in the window at `point`
    /// (Quartz; its front window when nil), matched to the title accessibility saw there.
    /// The first time, macOS asks to let ClickBait control the browser.
    func readBrowserTab(for flow: QuestionFlow, at point: Point?) {
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

    /// Its loudness, for the card's waveform.
    var cardMicrophoneLevel: Float { isCardRecording ? recorder.level : 0 }

    /// Starts the microphone for a card's voice panel. Nil, or why it can't.
    func startCardRecording() -> String? {
        guard !isCardRecording else { return nil }
        if let reason = voiceUnavailable() { return reason }
        if let error = startRecorder(for: "Card voice") { return "Couldn't start the microphone: \(error.localizedDescription)" }
        isCardRecording = true
        Log.ask.notice("Card voice: recording")
        // Never left on: a recording nobody stopped (a missed tap) held the microphone and
        // turned every dictation away as "busy" until a restart (2026-10-24).
        let session = UUID()
        cardRecordingSession = session
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, cardRecordingSession == session, isCardRecording else { return }
            dropCardRecording(reason: "a minute without a stop")
        }
        return nil
    }

    /// Stops a card's recording that's in the way (Esc, dictation, the minute's up) and tells
    /// its panel, so its button reads "voice" again.
    func dropCardRecording(reason: String) {
        guard isCardRecording else { return }
        cancelCardRecording()
        Log.ask.notice("Card voice: dropped (\(reason, privacy: .public))")
        onCardRecordingDropped?()
    }

    /// Why the microphone can't be used for a card's voice panel or dictation now, or nil.
    func voiceUnavailable() -> String? {
        guard state == .idle, currentFlow == nil, !isAnswering, !isCardRecording, !isDictating else {
            return "ClickBait is busy with a question. Try again in a moment."
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return "Microphone access is off. Open Permissions… from the menu bar icon."
        }
        switch speech.state {
        case .ready: return nil
        case .notDownloaded, .downloading, .importing: return "The speech model isn't downloaded yet. Open Settings… → Speech."
        case .loading: return "The speech model is still loading. Try again in a moment."
        case .failed(let message): return message
        }
    }

    /// Starts recording; nil, or the error (logged).
    func startRecorder(for use: String) -> Error? {
        speaker.stop()  // never record ClickBait talking
        do {
            try recorder.start()
            return nil
        } catch {
            Log.input.error("\(use, privacy: .public): recorder failed to start: \(error.localizedDescription, privacy: .public)")
            return error
        }
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
        let audio = await Task.detached(priority: .userInitiated) {
            AudioConditioner.condition(samples, sampleRate: AudioRecorder.sampleRate)
        }.value
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
}
