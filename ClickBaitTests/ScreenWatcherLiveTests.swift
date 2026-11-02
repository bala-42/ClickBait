import AppKit
import ClickBaitCore
import Foundation
import Testing
@testable import ClickBait

/// A real watch on the menu bar's date (opt-in: `TEST_RUNNER_CLICKBAIT_WATCH=<word>`; needs Screen Recording).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_WATCH"] != nil))
struct ScreenWatcherLiveTests {
    @Test func seesTheMenuBarDate() async throws {
        let word = ProcessInfo.processInfo.environment["CLICKBAIT_WATCH"] ?? "Nov"
        let screen = try #require(NSScreen.screens.first)
        let area = CGRect(x: screen.frame.maxX - 340, y: screen.frame.maxY - 26, width: 340, height: 26)
        var done: String?
        ScreenWatcher.shared.onDone = { done = $0 }
        ScreenWatcher.shared.start(area: area, rule: .says(word), blocklist: .defaults)
        for _ in 0..<40 where done == nil { try await Task.sleep(for: .milliseconds(250)) }
        print("WATCH reading: \(ScreenWatcher.shared.reading.prefix(80)) → \(done ?? "not yet")")
        ScreenWatcher.shared.stop()
        #expect(done != nil)
    }
}
