import AppKit
import AVFoundation
import ClickBaitCore
import Observation

// fn+⌃ dictation.
extension AskCoordinator {
    // MARK: - Dictation (fn+⌃, `DictationController`)


    /// Starts the microphone for dictation. Nil, or why it can't.
    func startDictation() -> String? {
        // Holding the dictation key is asked now: it takes the microphone from a card's recording.
        dropCardRecording(reason: "dictation")
        if let reason = voiceUnavailable() { return reason }
        if let error = startRecorder(for: "Dictation") { return "Couldn't start the microphone: \(error.localizedDescription)" }
        isDictating = true
        return nil
    }

    /// Stops the microphone and returns what was said ("" when nothing was), with `prompt`'s
    /// words as Whisper's spelling hints. Dictation stays on until `endDictation()`.
    func finishDictation(prompt: String) async -> Result<String, CardVoiceError> {
        guard isDictating else { return .failure(CardVoiceError(message: "The recording had already stopped.")) }
        let samples = recorder.stop()
        // Off the main thread: on a long recording it froze it ~110 ms (stall trap, 2026-10-25).
        let audio = await Task.detached(priority: .userInitiated) {
            AudioConditioner.condition(samples, sampleRate: AudioRecorder.sampleRate)
        }.value
        guard !audio.isSilent else { return .success("") }
        do {
            return .success(try await speech.transcribe(audio.samples, prompt: prompt))
        } catch {
            Log.ask.error("Dictation: transcription failed: \(error.localizedDescription, privacy: .public)")
            return .failure(CardVoiceError(message: "Couldn't understand the recording: \(error.localizedDescription)"))
        }
    }

    /// Dictation is over (finished or dropped): the microphone is off.
    func endDictation() {
        guard isDictating else { return }
        _ = recorder.stop()
        isDictating = false
    }

    /// Dictation's tidy-up: one short text-only request (`Prompt.dictationSystem`). Nil if it's
    /// slower than `Dictation.tidyLimit` or fails; the caller then uses the raw words.
    /// fn+⌃ writing: the request carried out by the local model; nil when it couldn't (never
    /// the raw request, which isn't text to type).
    func writeDictation(_ instruction: String, subject: String?, screen: String?, app: String?) async -> String? {
        var ask = AskRequest(question: "", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: ScreenContext(appName: app), selectedText: nil)
        ask.writeInstruction = instruction
        ask.writeSubject = subject
        ask.writeScreen = screen?.isEmpty == false ? screen : nil
        return DictationWriting.parse(await Self.reply(from: settings.makeProvider(), to: ask, within: .seconds(30)))
    }

    func tidyDictation(_ heard: String, app: String?, screenWords: String) async -> String? {
        var ask = AskRequest(question: "", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: ScreenContext(appName: app), selectedText: nil)
        ask.dictation = heard
        ask.screenWords = screenWords.isEmpty ? nil : screenWords
        return await Self.reply(from: settings.makeProvider(), to: ask, within: Dictation.tidyLimit(for: heard))
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
}
