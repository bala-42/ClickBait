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
        let view = PrompterView(studio: studio).padding(30).background(Color(red: 0.35, green: 0.37, blue: 0.75))
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.sharpRep())
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-studio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "prompter.png"))
    }
}
