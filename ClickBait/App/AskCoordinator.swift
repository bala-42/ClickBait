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
    /// Something went wrong answering in the chat.
    @ObservationIgnored var onChatError: ((String) -> Void)?
    /// The chat closed from this side (a new ⌥⌘ explanation replaces it).
    @ObservationIgnored var onChatClose: (() -> Void)?
    /// Called with the spoken answer so far while it streams in.
    @ObservationIgnored var onPartialAnswer: ((String) -> Void)?
    /// Called after a spoken command ran, with a short confirmation.
    @ObservationIgnored var onActionDone: ((String) -> Void)?
    /// Called with the parsed answer and its pointers mapped to screen points.
    @ObservationIgnored var onAnswer: ((AssistantResponse, [ScreenPointer]) -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let speech: SpeechModelManager
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let capturer = ScreenCapturer()
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
        case .explain: explain()
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
        guard conversation != nil else { return }
        speaker.stop()
        askTask?.cancel()
        askTask = nil
        conversation = nil
        isAnswering = false
        if state == .thinking || state == .speaking { state = .idle }
        Log.ask.notice("Chat closed")
    }

    /// A message typed into the open chat bubble. Replies to typed messages are text only.
    func sendTyped(_ text: String) {
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
        let provider = settings.makeProvider()
        self.provider = provider
        let blocklist = settings.blocklist
        askTask = Task {
            let startedAt = ContinuousClock.now
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
            await respond(question: text, selectedText: nil, capture: capture, encoding: encoding, startedAt: startedAt,
                          speak: false, display: text)
        }
    }

    /// Escape while listening or thinking abandons the question.
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
        Log.input.notice("Microphone started in \(String(describing: ContinuousClock.now - micStart), privacy: .public)")
        // Capture at press time: the screen the user is asking about is the one they
        // were looking at when they started talking.
        let blocklist = settings.blocklist
        captureTask = Task { [capturer] in try await capturer.captureDisplayUnderCursor(excluding: blocklist) }
        context = ScreenContext(appName: frontmost?.localizedName)
        let pid = frontmost?.processIdentifier
        frontmostPID = pid
        frontmostBundleID = frontmost?.bundleIdentifier
        snapshotTask = Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid) }
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

        let samples = recorder.stop()
        let releasedAt = ContinuousClock.now
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
        Log.ask.notice("""
            Captured \(samples.count, privacy: .public) samples (\(seconds, format: .fixed(precision: 2), privacy: .public)s), \
            screenshot \(capture.image.width, privacy: .public)x\(capture.image.height, privacy: .public)px \
            of display \(capture.displayID, privacy: .public) at \(capture.backingScale, privacy: .public)x
            """)

        if let snapshot = await snapshotTask?.value {
            context.windowTitle = snapshot.windowTitle
            context.focusedElement = snapshot.focusedElement
        }

        // Downscale while Whisper runs.
        let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(capture.image) }

        let transcript: String
        do {
            let start = ContinuousClock.now
            transcript = try await speech.transcribe(samples)
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
        onTranscript?(transcript)

        // Direct orders run right away, without the model.
        if settings.commandsEnabled,
           let command = CommandParser.parse(transcript, allowedShortcuts: settings.allowedShortcuts),
           !isUnknownApp(command) {
            Log.ask.notice("Command recognised: \(command.name, privacy: .public)")
            encoding.cancel()
            await perform(command)
            return
        }

        // With a chat open, a spoken question is a follow-up in it.
        await respond(question: transcript, selectedText: nil, capture: capture, encoding: encoding, startedAt: releasedAt,
                      speak: true, display: transcript)
    }

    // MARK: - Explain highlighted text (⌥⌘)

    private func explain() {
        guard state != .listening, state != .thinking, !isAnswering else { return }
        speaker.stop()
        if conversation != nil {
            closeChat()
            onChatClose?()
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
            show(error: "Highlight some text first, then press ⌥⌘.")
            return
        }
        guard !Task.isCancelled else { return }
        context.windowTitle = snapshot.windowTitle
        context.focusedElement = snapshot.focusedElement
        Log.ask.notice("Explain: \(selected.count, privacy: .public) characters selected via \(method.rawValue, privacy: .public)")
        onExplaining?(selected)

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

    // MARK: - Answering

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
        display: String
    ) async {
        let releasedAt = startedAt
        answerStartedAt = startedAt
        var spokeAnything = false
        guard let provider else { return }
        let history = conversation?.history ?? []
        if conversation == nil {
            conversation = Conversation()
            onChatOpen?(display)
        } else {
            onChatUserMessage?(display)
        }
        isAnswering = true
        defer { isAnswering = false }
        let reply: String
        let screenshot: EncodedScreenshot
        let request: AskRequest
        do {
            screenshot = try await encoding.value
            request = AskRequest(
                question: question,
                screenshotJPEG: screenshot.jpeg,
                screenshotWidth: screenshot.width,
                screenshotHeight: screenshot.height,
                context: context,
                selectedText: selectedText,
                history: history
            )
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
            let tidy: (String) -> String = { selectedText == nil ? $0 : ExplanationCleaner.clean($0) }
            for try await chunk in provider.stream(request) {
                if firstChunkAt == nil { firstChunkAt = .now }
                text += chunk
                let newSpeech = extractor.feed(chunk)
                if !newSpeech.isEmpty, !Task.isCancelled {
                    spokenSoFar += newSpeech
                    onPartialAnswer?(tidy(spokenSoFar))
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
            onChatError?(error.localizedDescription)
            return
        }

        if settings.keepDebugCaptures {
            DebugCaptureStore.saveReply(reply)
        }

        var parsed = ResponseParser.parse(reply, imageWidth: screenshot.width, imageHeight: screenshot.height)
        if selectedText != nil { parsed.response.speech = ExplanationCleaner.clean(parsed.response.speech) }
        // An ⌥⌘ explanation is about the text, never about where to click.
        if selectedText != nil, !parsed.response.pointers.isEmpty {
            Log.ask.notice("Explain: ignoring \(parsed.response.pointers.count, privacy: .public) pointer(s) the model added")
            parsed.response.pointers = []
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
        let pointers = await snap(modelPointers, geometry: geometry)
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
        conversation?.append(user: Prompt.userText(for: request), assistantSpeech: parsed.response.speech)
        // The answer lives in the chat bubble now; the companion goes back to its arrowhead.
        if state == .thinking || state == .speaking { state = .idle }
        onAnswer?(parsed.response, pointers)
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
    private func perform(_ request: ActionRequest) async {
        guard settings.commandsEnabled else { return }
        switch ActionCatalog.resolve(request, allowedShortcuts: settings.allowedShortcuts) {
        case .failure(let error):
            Log.ask.notice("Action refused: \(request.name, privacy: .public) (\(String(describing: error), privacy: .private))")
            speaker.stop()
            speaker.speak(error.message)
            show(error: error.message)
        case .success(let action):
            do {
                let confirmation = try await ActionExecutor.run(action)
                Log.ask.notice("Action done: \(request.name, privacy: .public)")
                if let started = answerStartedAt {
                    Log.ask.notice("Command finished \(String(describing: ContinuousClock.now - started), privacy: .public) after release")
                }
                speaker.speak(confirmation + ".")
                state = .speaking
                onActionDone?(confirmation)
            } catch {
                Log.ask.error("Action failed: \(request.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                speaker.stop()
                speaker.speak(error.localizedDescription)
                show(error: error.localizedDescription)
            }
        }
    }

    /// Moves each pointer onto a matching real element nearby, and drops pointers that
    /// don't land on or near anything clickable — the model sometimes points at empty
    /// space for questions that need no clicking. Without Accessibility permission
    /// there's no way to check, so pointers are returned unchanged.
    private func snap(_ pointers: [ScreenPointer], geometry: ScreenGeometry) async -> [ScreenPointer] {
        guard AXInspector.isTrusted else {
            Log.ask.notice("Snapping skipped: Accessibility not granted")
            return pointers
        }
        let pid = frontmostPID
        var snapped: [ScreenPointer] = []
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
            guard decision.candidate != nil else {
                Log.ask.notice("Pointer dropped: nothing clickable there")
                continue
            }
            snapped.append(moved ? ScreenPointer(
                label: pointer.label,
                appKit: geometry.appKitPoint(fromQuartz: decision.point),
                quartz: decision.point
            ) : pointer)
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
