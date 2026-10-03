@preconcurrency import AVFoundation
import os

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .converterUnavailable: "The microphone's audio format isn't supported."
        }
    }
}

/// Records the microphone into memory as 16 kHz mono Float32, the format WhisperKit
/// expects. Nothing is written to disk.
///
/// Bluetooth headsets (AirPods) switch from their listening profile to their mic
/// profile when recording starts, which reconfigures the audio hardware mid-recording.
/// AVAudioEngine stops when that happens, so the recorder listens for configuration
/// changes and reconnects, keeping what it already captured.
@MainActor
final class AudioRecorder {
    nonisolated static let sampleRate: Double = 16_000

    private var engine: AVAudioEngine?
    private var sink: SampleSink?
    /// An engine whose graph is already built, so pressing the hotkey only has to start
    /// it. Preparing doesn't open the microphone (no orange indicator). Discarded when
    /// the audio hardware changes, since its formats would be stale.
    private var preparedEngine: AVAudioEngine?
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    var isRecording: Bool { engine != nil }

    func prepare() {
        guard preparedEngine == nil else { return }
        let engine = AVAudioEngine()
        _ = engine.inputNode
        engine.prepare()
        observeConfigurationChanges(of: engine)
        preparedEngine = engine
    }

    func start() throws {
        guard engine == nil else { return }

        let engine = preparedEngine ?? AVAudioEngine()
        if preparedEngine == nil { observeConfigurationChanges(of: engine) }
        preparedEngine = nil

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        else { throw AudioRecorderError.converterUnavailable }

        let sink = SampleSink(outputFormat: outputFormat)
        do {
            try connect(engine, to: sink)
        } catch {
            stopObserving(engine)
            throw error
        }
        self.engine = engine
        self.sink = sink
    }

    /// How loud the microphone is right now (RMS, 0…1); 0 when not recording.
    var level: Float { sink?.level ?? 0 }

    /// Stops recording and returns everything captured since `start()`.
    func stop() -> [Float] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stopObserving(engine)
        self.engine = nil

        let samples = sink?.drain() ?? []
        sink = nil
        prepare()
        return samples
    }

    // MARK: - Engine

    private func connect(_ engine: AVAudioEngine, to sink: SampleSink) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        Log.input.notice("Microphone format: \(inputFormat.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) channel(s)")
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: Self.tapBlock(for: sink))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        let id = ObjectIdentifier(engine)
        observers[id] = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged(engineID: id) }
        }
    }

    private func stopObserving(_ engine: AVAudioEngine) {
        if let observer = observers.removeValue(forKey: ObjectIdentifier(engine)) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func configurationChanged(engineID: ObjectIdentifier) {
        if let prepared = preparedEngine, ObjectIdentifier(prepared) == engineID {
            stopObserving(prepared)
            preparedEngine = nil  // rebuilt on demand with the new hardware
            return
        }
        guard let engine, ObjectIdentifier(engine) == engineID, let sink else { return }
        // Mid-recording (e.g. AirPods switching to their mic): reconnect and carry on.
        do {
            try connect(engine, to: sink)
            Log.input.notice("Audio device changed while recording; reconnected")
        } catch {
            Log.input.error("Audio device changed while recording; reconnect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Built outside the main actor on purpose: a closure written inline here would be
    /// main-actor isolated, and Swift 6 traps when the audio thread calls it.
    private nonisolated static func tapBlock(for sink: SampleSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
    }
}

/// Receives buffers on the realtime audio thread, converts them, and accumulates
/// samples behind a lock. The converter is only ever touched under that lock, which
/// is what makes the unchecked Sendable conformance sound. A new converter is made
/// whenever the input format changes (the hardware was reconfigured).
private final class SampleSink: @unchecked Sendable {
    private struct State {
        var samples: [Float] = []
        /// RMS of the latest buffer, for the listening waveform.
        var level: Float = 0
        var converter: AVAudioConverter?
        var converterInput: AVAudioFormat?
    }

    private let outputFormat: AVAudioFormat
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        state.withLock { state in
            if state.converterInput != buffer.format {
                state.converter = AVAudioConverter(from: buffer.format, to: outputFormat)
                state.converterInput = buffer.format
            }
            guard let converter = state.converter else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let channel = output.floatChannelData?[0] else { return }
            let converted = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            state.samples.append(contentsOf: converted)
            if !converted.isEmpty {
                state.level = (converted.reduce(0) { $0 + $1 * $1 } / Float(converted.count)).squareRoot()
            }
        }
    }

    var level: Float { state.withLock { $0.level } }

    func drain() -> [Float] {
        state.withLock { state in
            defer { state.samples = [] }
            return state.samples
        }
    }
}
