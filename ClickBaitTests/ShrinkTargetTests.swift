import Foundation
import Testing
@testable import ClickBait
@testable import ClickBaitCore

/// Shrinking to an asked size, on copies of real files (opt-in):
/// `TEST_RUNNER_CLICKBAIT_SHRINK_TARGET=<video>|<bytes>|<image>|<bytes>`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_SHRINK_TARGET"] != nil))
struct ShrinkTargetTests {
    @Test func underTheAskedSize() async throws {
        let parts = (ProcessInfo.processInfo.environment["CLICKBAIT_SHRINK_TARGET"] ?? "").split(separator: "|").map(String.init)
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-shrink-target")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for pair in stride(from: 0, to: parts.count - 1, by: 2) {
            let source = URL(fileURLWithPath: parts[pair]), target = Int64(parts[pair + 1])!
            let copy = folder.appending(path: "item\(pair).\(source.pathExtension)")
            try FileManager.default.copyItem(at: source, to: copy)
            let start = Date()
            let (message, outputs) = try await FileActions.perform(.shrink(toBytes: target), on: [copy])
            let size = outputs.first.map { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value ?? 0 } ?? 0
            print("TARGET \(FileSize.label(target)): \(message) [\(size) bytes, \(String(format: "%.0f", Date().timeIntervalSince(start))) s]")
            #expect(size > 0 && size <= target)
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
