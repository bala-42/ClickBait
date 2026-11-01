import AVFoundation
import ClickBaitCore
import OSLog
import Speech

/// Studio's ears (user's ask, 2026-11-01: the prompter runs at your pace): Apple's on-device
/// speech recognition hears you live, `ScriptFollower` places what it hears in the script, and
/// the microphone's loudness drives the ring. Nothing is sent anywhere; nothing is kept.
@MainActor
final class VoiceFollower {
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var follower: ScriptFollower
    private var running = false
    /// Transcript before the current recognition task (each task is restarted after a while).
    private var earlier = ""
    private var lastLine = -1
    private let onPlace: (ScriptFollower.Place) -> Void
    private let onLevel: (Double) -> Void
    private let onProblem: (String) -> Void

    init(readable: String, onPlace: @escaping (ScriptFollower.Place) -> Void,
         onLevel: @escaping (Double) -> Void, onProblem: @escaping (String) -> Void) {
        follower = ScriptFollower(readable: readable)
        self.onPlace = onPlace
        self.onLevel = onLevel
        self.onProblem = onProblem
    }

    /// Reading resumes from `line` (a cue jump, or a scroll by hand).
    func resume(atLine line: Int) {
        follower.resume(atLine: line)
        earlier = ""
        restartRecognition()
    }

    func start() async {
        guard !running else { return }
        guard await Self.allowed() else {
            onProblem("allow Speech Recognition for ClickBait in System Settings → Privacy & Security")
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            onProblem("on-device speech recognition isn't available on this Mac")
            return
        }
        self.recognizer = recognizer
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let level = Self.level(buffer)
            Task { @MainActor in
                self?.request?.append(buffer)
                self?.onLevel(level)
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            onProblem("couldn't use the microphone: \(error.localizedDescription)")
            return
        }
        running = true
        restartRecognition()
        Log.app.notice("Studio: following the voice")
    }

    func stop() {
        guard running else { return }
        running = false
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onLevel(0)
    }

    /// A fresh recognition task (at the start, after a jump, and when one ends: tasks don't
    /// run forever).
    private func restartRecognition() {
        guard running, let recognizer else { return }
        task?.cancel()
        request?.endAudio()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true  // never sent to Apple
        request.taskHint = .dictation
        // The script's own words help it spell names and jargon the way the script does.
        request.contextualStrings = Array(Set(follower.words.map(\.text).filter { $0.count > 5 }).prefix(100))
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? (error != nil)
            Task { @MainActor in self?.heard(text, final: final) }
        }
    }

    private func heard(_ text: String?, final: Bool) {
        if let text, !text.isEmpty {
            if let place = follower.hear(earlier + " " + text) {
                if place.line != lastLine { Log.app.notice("Studio: voice at line \(place.line, privacy: .public)") }
                lastLine = place.line
                onPlace(place)
            }
            if final { earlier = String((earlier + " " + text).suffix(200)) }
        }
        if final { restartRecognition() }
    }

    /// Loudness 0…1 from a buffer (RMS, on a speech-friendly scale).
    nonisolated private static func level(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return Double(min(1, max(0, (decibels + 50) / 40)))  // −50 dB → 0, −10 dB → 1
    }

    private static func allowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}
