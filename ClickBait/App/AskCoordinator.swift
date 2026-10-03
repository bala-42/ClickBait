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
    /// The user started (true) or stopped marking part of the screen with ⌥⌘ held.
    @ObservationIgnored var onSnipMarking: ((Bool) -> Void)? {
        didSet { snipper.onMarkingChange = onSnipMarking }
    }
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
            switch snipper.isActive ? snipper.end() : .tap {
            case .tap: explain()
            case .snip(let kind, let region, let path): snip(kind, region: region, path: path)
            }
        case .explainCancelled: snipper.cancel()
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
            let elements = await Self.elements(in: capture, frontmostPID: pid)
            await respond(question: text, selectedText: nil, capture: capture, encoding: encoding, startedAt: startedAt,
                          speak: false, display: text, elements: elements)
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
                      speak: true, display: transcript, elements: await elementsTask.value)
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
            show(error: "Highlight text and tap ⌥⌘ — or hold ⌥⌘ and circle or drag a box around something.")
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

    /// The microphone's level while listening, for the waveform.
    var microphoneLevel: Float { state == .listening ? recorder.level : 0 }

    // MARK: - Element list

    /// Enough to cover a window and an open menu without slowing a local model much.
    private static let maxListedElements = 100

    /// What Accessibility says is clickable on the captured display (off the main thread).
    private static func elements(in capture: ScreenCapture, frontmostPID pid: pid_t?) async -> [ScreenElement] {
        let frame = capture.displayFrame
        let display = Rect(x: frame.minX, y: capture.primaryDisplayHeight - frame.maxY, width: frame.width, height: frame.height)
        let start = ContinuousClock.now
        let elements = await Task.detached(priority: .userInitiated) {
            AXInspector.visibleElements(frontmostPID: pid, display: display)
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
    private func snip(_ kind: SnipKind, region: Rect, path: [Point]) {
        guard state != .listening, state != .thinking, !isAnswering else { return }
        speaker.stop()
        if conversation != nil {
            closeChat()
            onChatClose?()
        }
        errorResetTask?.cancel()

        let frontmost = NSWorkspace.shared.frontmostApplication
        guard checkCanAsk(frontmost: frontmost) else { return }
        frontmostPID = frontmost?.processIdentifier
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
        let encoding = Task.detached(priority: .userInitiated) {
            try ScreenshotEncoder.encode(SnipRenderer.render(capture, kind: kind, region: region, path: path))
        }
        await respond(question: "", selectedText: nil, capture: capture, encoding: encoding, startedAt: startedAt,
                      speak: false, display: kind == .circled ? "Explain what I circled" : "Explain what I boxed",
                      snip: kind)
    }

    // MARK: - Answering

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
        elements: [ScreenElement] = []
    ) async {
        let releasedAt = startedAt
        answerStartedAt = startedAt
        var spokeAnything = false
        guard let provider else { return }
        if conversation != nil, !chatShown { conversation = nil }  // an earlier pointing answer: start fresh
        let history = conversation?.history ?? []
        if conversation == nil {
            conversation = Conversation()
            if !speak {  // explain: show the bubble right away, the answer streams into it
                chatShown = true
                onChatOpen?(display)
            }
        } else {
            onChatUserMessage?(display)
        }
        isAnswering = true
        defer { isAnswering = false }
        let reply: String
        let screenshot: EncodedScreenshot
        let request: AskRequest
        var listed: [PromptElement] = []
        do {
            screenshot = try await encoding.value
            listed = PromptElement.list(elements, geometry: capture.geometry(imageWidth: screenshot.width, imageHeight: screenshot.height),
                                        limit: Self.maxListedElements)
            request = AskRequest(
                question: question,
                screenshotJPEG: screenshot.jpeg,
                screenshotWidth: screenshot.width,
                screenshotHeight: screenshot.height,
                context: context,
                selectedText: selectedText,
                history: history,
                snip: history.isEmpty ? snip : nil,
                elements: listed
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
            let explaining = selectedText != nil || snip != nil
            let tidy: (String) -> String = { explaining ? ExplanationCleaner.clean($0) : $0 }
            for try await chunk in provider.stream(request) {
                if firstChunkAt == nil { firstChunkAt = .now }
                text += chunk
                let newSpeech = extractor.feed(chunk)
                if !newSpeech.isEmpty, !Task.isCancelled {
                    spokenSoFar += newSpeech
                    if chatShown { onPartialAnswer?(tidy(spokenSoFar)) }
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

        var parsed = ResponseParser.parse(reply, imageWidth: screenshot.width, imageHeight: screenshot.height, elements: listed)
        if selectedText != nil || snip != nil { parsed.response.speech = ExplanationCleaner.clean(parsed.response.speech) }
        // An ⌥⌘ explanation is about the text or area, never about where to click (and a
        // snip's close-up has no screen coordinates anyway).
        if selectedText != nil || snip != nil, !parsed.response.pointers.isEmpty {
            Log.ask.notice("Explain: ignoring \(parsed.response.pointers.count, privacy: .public) pointer(s) the model added")
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
        conversation?.append(user: Prompt.userText(for: request), assistantSpeech: parsed.response.speech,
                             code: parsed.response.code, language: parsed.response.language)
        // The answer lives in the chat bubble now; the companion goes back to its arrowhead.
        if state == .thinking || state == .speaking { state = .idle }
        if !chatShown, pointers.isEmpty {
            chatShown = true
            onChatOpen?(display)
        }
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
            onActionStarted?(Self.workingMessage(for: action))
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
        case .file(let file):
            switch file {
            case .compress: "Compressing…"
            case .merge: "Merging…"
            case .convertImages: "Converting…"
            case .moveIntoNewFolder: "Making a new folder…"
            case .moveToTrash: "Moving to the Trash…"
            case .shrink: "Making smaller copies…"
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
            // Nothing to snap to (sidebar rows, canvases, web content…): trust the model's
            // point. Useless pointers are kept away by the prompt and the parser instead.
            guard decision.candidate != nil else {
                Log.ask.notice("Pointer kept as is: \(probe.seesContent ? "no matching element" : "accessibility can't see this area", privacy: .public)")
                snapped.append(pointer)
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
