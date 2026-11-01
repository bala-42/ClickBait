import AppKit
import SwiftUI
import Testing
@testable import ClickBait

/// Studio's prompter with a sample script, to look at (ClickBaitTests-studio).
@MainActor
struct StudioRenderTests {
    @Test func prompterDraws() throws {
        let studio = StudioModel.shared
        let saved = studio.text
        defer { studio.text = saved }
        studio.text = "# Intro\nHi, I'm Bala, and this is ClickBait.\nA little triangle that lives by your cursor.\n\n# The notch\nIt runs on this Mac."
        defer { studio.cuesOpen = false; studio.level = 0 }
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-studio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, level, cues) in [("prompter-rest", 0.0, false), ("prompter-voice", 0.85, false), ("prompter-cues", 0.3, true)] {
            studio.level = level
            studio.cuesOpen = cues
            let height = studio.size.height + (cues ? 8 + PrompterController.cueListHeight(studio.script.cues.count) : 0)
            let view = PrompterView(studio: studio).frame(height: height).padding(30).background(Color(red: 0.35, green: 0.37, blue: 0.75))
            let host = NSHostingView(rootView: view)
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.sharpRep())
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: name + ".png"))
        }
    }

    @Test func switchDraws() throws {
        let row = HStack(spacing: 20) {
            StudioSwitch(mode: .constant(.mirror))
            StudioSwitch(mode: .constant(.prompter))
        }.padding(20).background(Color.black)
        let host = NSHostingView(rootView: row)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.sharpRep())
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-studio")
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "switch.png"))
    }
}
