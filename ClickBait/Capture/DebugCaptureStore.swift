import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Debug-only: keeps the most recent screenshot and recording in a temp folder so
/// they can be inspected. Only used when "Keep last capture" is on in Settings;
/// otherwise nothing is ever written to disk.
enum DebugCaptureStore {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "ClickBait-debug", directoryHint: .isDirectory)
    }

    static func save(_ capture: ScreenCapture, samples: [Float], transcript: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePNG(capture.image, to: directory.appending(path: "last-screenshot.png"))
        try writeWAV(samples, to: directory.appending(path: "last-recording.wav"))
        try transcript.write(to: directory.appending(path: "last-transcript.txt"), atomically: true, encoding: .utf8)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func writeWAV(_ samples: [Float], to url: URL) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
            let channel = buffer.floatChannelData?[0]
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
