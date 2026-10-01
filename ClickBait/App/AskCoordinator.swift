import AppKit
import AVFoundation
import ClickBaitCore
import Observation

enum AskState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case error(String)
}

/// Runs one ask from hotkey press to answer: idle → listening → thinking → speaking.
/// Later steps plug the overlay and speech into `finish`.
@MainActor
@Observable
final class AskCoordinator {
    /// Taps shorter than this are treated as accidental and dropped silently.
    private static let minimumHold: Duration = .milliseconds(250)
    private static let errorDisplayTime: Duration = .seconds(4)

    private(set) var state: AskState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    @ObservationIgnored var onStateChange: ((AskState) -> Void)?
    /// Called with what Whisper heard, until the overlay bubble can show it (step 7).
    @ObservationIgnored var onTranscript: ((String) -> Void)?
    /// Called with the model's raw reply, until the parser and overlay exist (steps 6–7).
    @ObservationIgnored var onAnswer: ((String) -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let speech: SpeechModelManager
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let capturer = ScreenCapturer()
    @ObservationIgnored private var captureTask: Task<ScreenCapture, Error>?
    @ObservationIgnored private var pressedAt: ContinuousClock.Instant?
    @ObservationIgnored private var context = ScreenContext()
    @ObservationIgnored private var provider: (any LLMProvider)?
    @ObservationIgnored private var errorResetTask: Task<Void, Never>?

    init(settings: AppSettings, speech: SpeechModelManager) {
        self.settings = settings
        self.speech = speech
        recorder.prepare()
    }

    func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .pressed: begin()
        case .released: Task { await finish() }
        case .cancelled: cancel(reason: "another key was pressed")
        }
    }

    private func begin() {
        guard state != .listening, state != .thinking else { return }
        errorResetTask?.cancel()

        let frontmost = NSWorkspace.shared.frontmostApplication
        if settings.blocklist.isBlocked(bundleID: frontmost?.bundleIdentifier) {
            let name = frontmost?.localizedName ?? "this app"
            Log.ask.notice("Refused: frontmost app is on the blocklist")
            show(error: "ClickBait doesn't look at \(name) — it's on your blocklist.")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            show(error: "Microphone access is off. Open Permissions… from the menu bar icon.")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            show(error: "Screen Recording is off. Open Permissions… from the menu bar icon.")
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
        if settings.provider == .anthropic, (KeychainStore.read(.anthropicAPIKey) ?? "").isEmpty {
            show(error: LLMError.missingAPIKey.localizedDescription)
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
        // Load a cold local model while the user is still talking. Sends no user content.
        let provider = settings.makeProvider()
        self.provider = provider
        Task.detached(priority: .userInitiated) { await provider.warmUp() }
        state = .listening
        Log.ask.notice("Listening (frontmost: \(frontmost?.bundleIdentifier ?? "none", privacy: .private))")
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

        guard !transcript.isEmpty else {
            show(error: "I didn't catch that. Hold Control+Option and try again.")
            return
        }
        onTranscript?(transcript)

        guard let provider else { return }
        let reply: String
        do {
            let screenshot = try await encoding.value
            let request = AskRequest(
                question: transcript,
                screenshotJPEG: screenshot.jpeg,
                screenshotWidth: screenshot.width,
                screenshotHeight: screenshot.height,
                context: context
            )
            Log.ask.notice("""
                Asking \(provider.displayName, privacy: .public) with a \(screenshot.width, privacy: .public)x\(screenshot.height, privacy: .public) \
                JPEG (\(screenshot.jpeg.count / 1024, privacy: .public) KB, downscale \(screenshot.downscale, format: .fixed(precision: 3), privacy: .public))
                """)
            var text = ""
            var firstChunkAt: ContinuousClock.Instant?
            for try await chunk in provider.stream(request) {
                if firstChunkAt == nil { firstChunkAt = .now }
                text += chunk
            }
            reply = text
            let firstChunk = firstChunkAt.map { String(describing: $0 - releasedAt) } ?? "none"
            Log.ask.notice("""
                Reply: first chunk \(firstChunk, privacy: .public) after release, complete after \
                \(String(describing: ContinuousClock.now - releasedAt), privacy: .public), \(reply.count, privacy: .public) characters
                """)
        } catch {
            Log.ask.error("Provider failed: \(error.localizedDescription, privacy: .public)")
            show(error: error.localizedDescription)
            return
        }

        if settings.keepDebugCaptures {
            DebugCaptureStore.saveReply(reply)
        }
        onAnswer?(reply)

        // The response parser, pointing and speech are added in later steps.
        state = .idle
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
