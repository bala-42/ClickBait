import AVFoundation
import ClickBaitCore
import OSLog
import os

/// Studio's ears (user's ask, 2026-11-01: the prompter runs at your pace). The microphone's
/// last 4 seconds are transcribed by ClickBait's own speech model (Whisper, already loaded for
/// dictation) about every 0.6 s while you speak, `ScriptFollower` places the words in the
/// script, and the microphone's loudness drives the ring. Needs only the microphone: Apple's
/// live recognizer refused outright with Siri and Dictation off (user's Mac, 2026-11-01).
/// Nothing is sent anywhere; nothing is kept.
@MainActor
final class VoiceFollower {
    /// Set by the app delegate: ClickBait's speech model (16 kHz mono samples, a prompt to
    /// steer spelling) → text, or nil when it isn't ready.
    static var transcribe: (([Float], String?) async -> String?)?

    private let engine = AVAudioEngine()
    private var follower: ScriptFollower
    private var running = false
    private var listening: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private let audio = Recording()
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

    /// Reading resumes from `line` (a cue jump, or a scroll by hand); what was heard before is dropped.
    func resume(atLine line: Int) {
        follower.resume(atLine: line)
        audio.clear()
        Log.app.notice("Studio: resuming at line \(line, privacy: .public)")
    }

    func start() async {
        guard !running else { return }
        guard Self.transcribe != nil else { onProblem("the speech model isn't ready yet"); return }
        Microphones.apply(to: engine)  // the microphone chosen in Settings, as dictation uses
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            onProblem("couldn't use the microphone")
            return
        }
        input.removeTap(onBus: 0)
        // Built off the main actor: the audio arrives on its own thread, and a block tied to
        // the main actor there stopped the app at once (user's report: "nothing happens").
        input.installTap(onBus: 0, bufferSize: 2048, format: format,
                         block: Self.tap(audio: audio, converter: converter, target: target))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            onProblem("couldn't use the microphone: \(error.localizedDescription)")
            return
        }
        running = true
        Log.app.notice("Studio: following the voice (microphone \(Int(format.sampleRate), privacy: .public) Hz)")
        listening = Task { [weak self] in await self?.listen() }
        // The ring: the latest loudness, ~30 times a second.
        meter = Task { [weak self] in
            while let self, running, !Task.isCancelled {
                onLevel(audio.latestLevel)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        listening?.cancel()
        listening = nil
        meter?.cancel()
        meter = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onLevel(0)
    }

    /// While running: the last 4 s transcribed every ~0.6 s, only when someone spoke in the
    /// last 1.5 s (silence makes Whisper invent words — "thanks for watching" among them).
    private func listen() async {
        var heard = 0
        var ticks = 0
        while running, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(350))
            ticks += 1
            if ticks % 5 == 0 {
                Log.app.notice("Studio: loudest \(String(format: "%.2f", self.audio.takePeak()), privacy: .public), room \(String(format: "%.2f", self.audio.roomLevel), privacy: .public), speaking \(self.audio.spokeRecently(within: 3), privacy: .public)")
            }
            guard running, audio.spokeRecently(within: 1.5), let transcribe = Self.transcribe else { continue }
            // Lifted like dictation's recordings (a quiet voice, 0.03–0.21 here, gave Whisper
            // near-silence and stray single words); nothing above hiss isn't transcribed.
            // Lifted up to 40× (dictation's 12× and its silence bar left a quiet voice unheard:
            // peaks of 0.12–0.19 here); speech was already judged against the room.
            let heardAudio = AudioConditioner.condition(audio.last(seconds: 3), sampleRate: 16_000, silence: 0.002, maxGain: 40)
            guard heardAudio.samples.count > 8_000, !heardAudio.isSilent else { continue }
            let samples = heardAudio.samples
            // What's been read steers Whisper's spelling (the script ahead as a prompt, Whisper
            // "said" it: "…now Studio has a" before it was read).
            let ahead = follower.readSoFar()
            let began = ContinuousClock.now
            let result = await transcribe(samples, ahead)
            Log.app.notice("Studio: try → \(String((result ?? "nil").prefix(80)), privacy: .public)")
            guard let text = result, !text.isEmpty else { continue }
            let took = ContinuousClock.now - began
            heard += 1
            if heard <= 3 || heard % 20 == 0 || took > .seconds(1.5) {
                Log.app.notice("Studio: heard \(text.split(separator: " ").count, privacy: .public) words in \(String(describing: took), privacy: .public)")
            }
            if let place = follower.hear(text) {
                if place.line != lastLine { Log.app.notice("Studio: voice at line \(place.line, privacy: .public)") }
                lastLine = place.line
                onPlace(place)
            }
        }
    }

    /// The microphone tap: on the audio thread, never the main actor.
    nonisolated private static func tap(audio: Recording, converter: AVAudioConverter, target: AVAudioFormat) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let converter = converter
        return { buffer, _ in
            audio.append(convert(buffer, with: converter, to: target), level: level(buffer))
        }
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

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    /// The microphone's last few seconds at 16 kHz, and when speech was last loud enough.
    private final class Recording: Sendable {
        private struct State {
            var samples: [Float] = []; var spokeAt = Date.distantPast; var peak = 0.0; var level = 0.0
            /// The room's own level (falls at once to quieter, creeps up slowly): speech is
            /// judged against it, not a fixed bar (the user's real voice peaked at 0.13–0.29 on
            /// a bar of 0.3 set with the Mac's voice through speakers, and was never heard).
            var floor = 0.2
            /// Buffers in a row loud enough to be speech.
            var loudRun = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private static let keep = 16_000 * 6
        /// Speech: this far above the room's level (about 3 dB on the scale above).
        private static let aboveRoom = 0.07

        func append(_ samples: [Float], level: Double) {
            state.withLock { state in
                state.samples += samples
                if state.samples.count > Self.keep { state.samples.removeFirst(state.samples.count - Self.keep) }
                state.floor = level < state.floor ? level : state.floor + (level - state.floor) * 0.002
                let voice = max(0, level - state.floor)
                if voice > Self.aboveRoom { state.spokeAt = Date() }
                state.peak = max(state.peak, level)
                // The ring moves only for speech: above the speech bar for 2 buffers running
                // (~85 ms), so room noise and clicks or typing leave it still (user's ask, 2026-11-02).
                state.loudRun = voice > Self.aboveRoom ? state.loudRun + 1 : 0
                state.level = state.loudRun >= 2 ? min(1, (voice - Self.aboveRoom) / 0.2) : 0
            }
        }

        var latestLevel: Double { state.withLock { $0.level } }
        var roomLevel: Double { state.withLock { $0.floor } }

        /// The loudest level since last asked (for the log).
        func takePeak() -> Double {
            state.withLock { state in defer { state.peak = 0 }; return state.peak }
        }

        func last(seconds: Double) -> [Float] {
            state.withLock { Array($0.samples.suffix(Int(seconds * 16_000))) }
        }

        func spokeRecently(within seconds: Double) -> Bool {
            state.withLock { Date().timeIntervalSince($0.spokeAt) < seconds }
        }

        func clear() {
            state.withLock { $0.samples.removeAll() }
        }
    }
}
