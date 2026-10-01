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
@MainActor
final class AudioRecorder {
    nonisolated static let sampleRate: Double = 16_000

    private var engine: AVAudioEngine?
    private var sink: SampleSink?

    var isRecording: Bool { engine != nil }

    func start() throws {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw AudioRecorderError.converterUnavailable
        }

        let sink = SampleSink(converter: converter, outputFormat: outputFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: Self.tapBlock(for: sink))

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.sink = sink
    }

    /// Built outside the main actor on purpose: a closure written inline here would be
    /// main-actor isolated, and Swift 6 traps when the audio thread calls it.
    private nonisolated static func tapBlock(for sink: SampleSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
    }

    /// Stops recording and returns everything captured since `start()`.
    func stop() -> [Float] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        let samples = sink?.drain() ?? []
        sink = nil
        return samples
    }
}

/// Receives buffers on the realtime audio thread, converts them, and accumulates
/// samples behind a lock. The converter is only ever touched under that lock, which
/// is what makes the unchecked Sendable conformance sound.
private final class SampleSink: @unchecked Sendable {
    private struct State {
        var samples: [Float] = []
    }

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        state.withLock { state in
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
            state.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
    }

    func drain() -> [Float] {
        state.withLock { state in
            defer { state.samples = [] }
            return state.samples
        }
    }
}
