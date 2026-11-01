import AVFoundation
import Observation

/// Reads answers aloud with the system voices or a Kokoro voice (`KokoroVoice`), both on this
/// Mac. Sentences are queued as they finish streaming in, so speech starts before the whole
/// reply has arrived.
@MainActor
final class Speaker: NSObject {
    /// Called when the first sentence of an answer starts playing.
    var onStart: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let settings: AppSettings
    private var pending = 0
    private var hasStarted = false
    /// Kokoro: sentences made one after another (`kokoroChain`) and played in order; `round`
    /// changes on stop, so a stopped answer's leftovers neither play nor count.
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var kokoroChain: Task<Void, Never>?
    private var round = 0

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { pending > 0 }

    /// `force`: read even with "Read answers aloud" off (the results card's Listen again).
    func speak(_ sentence: String, force: Bool = false) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.speakAnswers || force, !text.isEmpty else { return }
        if let voice = KokoroVoice.name(in: settings.voiceIdentifier), KokoroVoice.isInstalled {
            speakWithKokoro(text, voice: voice)
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: settings.voiceIdentifier)
        utterance.rate = Float(settings.speechRate)
        utterance.postUtteranceDelay = 0.05
        pending += 1
        synthesizer.speak(utterance)
    }

    /// Stops immediately and forgets the queue (new question, Escape, dismiss).
    func stop() {
        // Only when something was queued: asking the synthesizer `isSpeaking` is a call to
        // the speech service that took ~100 ms on the main thread (the companion froze at
        // every press of the talk keys).
        guard pending > 0 || hasStarted else { return }
        pending = 0
        hasStarted = false
        round += 1
        kokoroChain?.cancel()
        kokoroChain = nil
        if player.engine != nil { player.stop() }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func speakWithKokoro(_ text: String, voice: String) {
        pending += 1
        let round = round
        // The rate slider (0.4…0.62, 0.5 normal) as Kokoro's speed.
        let speed = Float(min(1.3, max(0.75, settings.speechRate / 0.5)))
        let previous = kokoroChain
        kokoroChain = Task { [weak self] in
            await previous?.value
            let samples = await Task.detached(priority: .userInitiated) {
                await KokoroEngine.shared.loadIfInstalled()
                return await KokoroEngine.shared.audio(for: text, voice: voice, speed: speed)
            }.value
            guard let self, !Task.isCancelled, round == self.round else { return }
            guard let samples, let buffer = Self.buffer(samples) else {
                // Kokoro couldn't say it: the system voice does instead.
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = Self.voice(for: nil)
                utterance.rate = Float(settings.speechRate)
                synthesizer.speak(utterance)
                return
            }
            play(buffer, round: round)
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer, round: Int) {
        if player.engine == nil {
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: buffer.format)
        }
        if !audioEngine.isRunning { try? audioEngine.start() }
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self, round == self.round else { return }
                self.utteranceFinished()
            }
        }
        if !player.isPlaying { player.play() }
        utteranceStarted()
    }

    private static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
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
