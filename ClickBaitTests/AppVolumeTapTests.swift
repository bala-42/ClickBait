import CoreAudio
import Foundation
import Testing
@testable import ClickBait

/// A real tap on a playing sound (opt-in: `TEST_RUNNER_CLICKBAIT_TAP=1`; needs the audio capture permission).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_TAP"] != nil))
struct AppVolumeTapTests {
    @Test func tapsAPlayingSound() async throws {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.05", "/System/Library/Sounds/Submarine.aiff"]
        try player.run()
        defer { player.terminate() }
        var app: SystemAudio.PlayingApp?
        for _ in 0..<30 where app == nil {
            try await Task.sleep(for: .milliseconds(100))
            app = SystemAudio.playingApps().first { $0.pid == player.processIdentifier }
        }
        print("TAP playing apps: \(SystemAudio.playingApps().map(\.name)); afplay found: \(app != nil)")
        let output = try #require(SystemAudio.outputs().first { $0.id == SystemAudio.defaultOutput })
        let found = try #require(app)
        let tap = AppVolumeTap(process: found.id, outputUID: output.uid, gain: 0.5)
        print("TAP made: \(tap != nil) on \(output.name)")
        try await Task.sleep(for: .milliseconds(600))
        print("TAP buffers played: \(tap?.framesProcessed ?? -1)")
        tap?.stop()
        #expect((tap?.framesProcessed ?? 0) > 0)
    }
}
