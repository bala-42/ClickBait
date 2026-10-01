import AVFoundation
import Observation

/// Reads answers aloud with the system voices (on-device, free). Sentences are queued
/// as they finish streaming in, so speech starts before the whole reply has arrived.
@MainActor
final class Speaker: NSObject {
    /// Called when the first sentence of an answer starts playing.
    var onStart: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let settings: AppSettings
    private var pending = 0
    private var hasStarted = false

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { pending > 0 }

    func speak(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.speakAnswers, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: settings.voiceIdentifier)
        utterance.rate = Float(settings.speechRate)
        utterance.postUtteranceDelay = 0.05
        pending += 1
        synthesizer.speak(utterance)
    }

    /// Stops immediately and forgets the queue (new question, Escape, dismiss).
    func stop() {
        pending = 0
        hasStarted = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// Plays a sample in Settings.
    func preview() {
        stop()
        speak("Hi, I'm ClickBait. Hold Control and Option, and ask me anything about your screen.")
    }

    /// The chosen voice, else the best-quality voice for the system language.
    static func voice(for identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Voices for the Settings picker: the system language's region first, best quality first.
    static var availableVoices: [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted {
                if ($0.language == language) != ($1.language == language) { return $0.language == language }
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.name < $1.name
            }
    }

    fileprivate func utteranceStarted() {
        guard !hasStarted, pending > 0 else { return }
        hasStarted = true
        onStart?()
    }

    fileprivate func utteranceFinished() {
        guard pending > 0 else { return }
        pending -= 1
        if pending == 0 { hasStarted = false }
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceStarted() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceFinished() }
    }
}

extension AVSpeechSynthesisVoiceQuality {
    var label: String {
        switch self {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Default"
        }
    }
}
