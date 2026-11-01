import AppKit
import ClickBaitCore
import SwiftUI
import Testing
@testable import ClickBait

/// Studio's prompter for real, on screen, with a script of its own (opt-in: it shows a window
/// for a few seconds): `TEST_RUNNER_CLICKBAIT_STUDIO_LIVE=1 xcodebuild test … -only-testing:ClickBaitTests/StudioLiveTests`.
/// Screenshots are taken from outside meanwhile (a sharing-hidden window can't photograph itself).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_STUDIO_LIVE"] == "1"))
struct StudioLiveTests {
    static let script = """
        # Hello
        Hi, I'm Bala. This is ClickBait, a little triangle that lives by your cursor.
        Ask about anything on your screen. It all runs on this Mac.

        # The notch
        Up here, the notch holds your music, a shelf for files, and now Studio.
        Studio has a mirror for quick checks, and this teleprompter.

        Smart search:
        Find a picture by what's in it. Find that note about the plumber.

        ---
        Thanks for watching. Bye for now!
        """

    @Test func prompterShowsScrollsJumpsAndHidesFromSharing() async throws {
        let studio = StudioModel.shared
        let saved = (studio.text, studio.name)
        defer { studio.stopPrompting(); studio.text = saved.0; studio.name = saved.1 }
        studio.text = Self.script
        #expect(studio.script.cues.map(\.title) == ["Hello", "The notch", "Smart search", "Thanks for watching. Bye for now!"])

        studio.startPrompting()
        try await Task.sleep(for: .seconds(1))
        let pid = ProcessInfo.processInfo.processIdentifier
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let mine = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        for window in mine { print("STUDIO window: \(window[kCGWindowBounds as String]!) layer \(window[kCGWindowLayer as String]!) sharing \(window[kCGWindowSharingState as String]!)") }
        let size = studio.size
        let prompter = mine.first { window in
            guard let bounds = window[kCGWindowBounds as String] as? [String: Double] else { return false }
            return abs((bounds["Width"] ?? 0) - size.width) < 1 && abs((bounds["Height"] ?? 0) - size.height) < 1
        }
        print("STUDIO windows on screen: \(mine.count); prompter: \(prompter.map { "\($0[kCGWindowBounds as String]!) sharing \($0[kCGWindowSharingState as String]!)" } ?? "none")")
        // A look at it, from inside (this process may photograph its own windows): the area under the notch.
        try snapshot("live-1-start")
        #expect(prompter != nil)
        #expect((prompter?[kCGWindowSharingState as String] as? Int) == 0)  // hidden from capture and sharing

        // 4 s on screen for the outside screenshot (hidden), then 4 s capturable for a look.
        try await Task.sleep(for: .seconds(4))
        NSApp.windows.first { $0.sharingType == .none && $0.level == WindowLayers.notch }?.sharingType = .readOnly
        print("STUDIO now capturable")
        try await Task.sleep(for: .seconds(4))

        let before = studio.offset
        studio.playing = true
        try await Task.sleep(for: .seconds(3))
        studio.playing = false
        try snapshot("live-2-scrolled")
        print("STUDIO scrolled \(Int(studio.offset - before)) pt in 3 s at \(Int(studio.speed)) pt/s")
        #expect(studio.offset - before > studio.speed * 2)

        studio.goTo(studio.script.cues[2])
        try await Task.sleep(for: .seconds(1.5))
        try snapshot("live-3-jumped")
        print("STUDIO jumped to “Smart search”: offset \(Int(studio.offset))")
        try await Task.sleep(for: .seconds(3))
    }

    /// The prompter window's live contents, drawn (a sharing-hidden window can't be screen-captured).
    private func snapshot(_ name: String) throws {
        guard let view = NSApp.windows.first(where: { $0.level == WindowLayers.notch && $0.isVisible })?.contentView,
              let rep = view.sharpRep() else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-studio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: name + ".png"))
    }
}
