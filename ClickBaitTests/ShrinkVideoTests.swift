import Foundation
import Testing
@testable import ClickBait

/// Shrinking real videos (opt-in, it re-encodes): `TEST_RUNNER_CLICKBAIT_SHRINK_VIDEOS=<file>:<file>`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_SHRINK_VIDEOS"] != nil))
struct ShrinkVideoTests {
    @Test func videosComeOutSmaller() async throws {
        let sources = (ProcessInfo.processInfo.environment["CLICKBAIT_SHRINK_VIDEOS"] ?? "").split(separator: ":").map(String.init)
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-shrink")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copies: [URL] = []
        for source in sources {
            let copy = folder.appending(path: URL(fileURLWithPath: source).lastPathComponent)
            try FileManager.default.copyItem(atPath: source, toPath: copy.path)
            copies.append(copy)
        }
        let start = Date()
        let (message, outputs) = try await FileActions.perform(.shrink(toBytes: nil), on: copies)
        print("SHRINK \(message) in \(Int(Date().timeIntervalSince(start))) s")
        for output in outputs { print("SHRINK made \(output.lastPathComponent)") }
        #expect(outputs.count == copies.count)
        try? FileManager.default.removeItem(at: folder)
    }
}
