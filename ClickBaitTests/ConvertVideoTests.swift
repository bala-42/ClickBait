import AVFoundation
import Foundation
import Testing
@testable import ClickBait
@testable import ClickBaitCore

/// Turning a real video into each format (opt-in): `TEST_RUNNER_CLICKBAIT_CONVERT_VIDEO=<file>`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_CONVERT_VIDEO"] != nil))
struct ConvertVideoTests {
    @Test func everyFormat() async throws {
        let source = ProcessInfo.processInfo.environment["CLICKBAIT_CONVERT_VIDEO"] ?? ""
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-convert")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: "clip.mp4")
        try FileManager.default.copyItem(atPath: source, toPath: copy.path)
        for format in MediaFormat.allCases {
            let start = Date()
            let (message, outputs) = try await FileActions.perform(.convertVideos(to: format), on: [copy])
            let size = outputs.first.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.intValue } ?? 0
            var playable = false
            if let output = outputs.first, format != .gif { playable = try await AVURLAsset(url: output).load(.isPlayable) }
            print("CONVERT \(format.rawValue): \(message) → \(outputs.first?.lastPathComponent ?? "-"), \(size / 1024) KB, playable \(playable), \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
            #expect(size > 0)
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
