import AppKit
import ClickBaitCore
import SwiftUI
import Testing
@testable import ClickBait

/// The Vision Memory settings and the in-card description editor (chat glass and notch), to look at.
@MainActor
struct VisionMemoryRenderTests {
    @Test func settingsAndEditorDraw() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-vision")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ClickBaitTests-vision")!)
        settings.visionExcluded = []
        try draw(VStack { VisionMemorySection(settings: settings) }
            .frame(width: 640).background(SettingsLook.card).padding(20).background(SettingsLook.page), to: folder.appending(path: "settings.png"))
        let item = SmartSearch.Item(id: "x", kind: .image, title: "The_Garden_of_Earthly_Delights_by_Bosch.jpg", place: "Downloads",
                                    text: "", caption: "A chaotic, allegorical scene depicts mythological figures, strange creatures and nude people in a fantastical landscape.")
        for notch in [false, true] {
            try draw(DescriptionEditor(item: item) { _ in }.environment(\.resultsInNotch, notch)
                .frame(width: 480).padding(16).background(notch ? Color.black : Color(white: 0.12)),
                     to: folder.appending(path: notch ? "editor-notch.png" : "editor-chat.png"))
        }
    }

    private func draw(_ view: some View, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.sharpRep())
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
