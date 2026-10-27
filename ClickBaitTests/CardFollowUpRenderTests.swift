import AppKit
import ClickBaitCore
import SwiftUI
import Testing
@testable import ClickBait

/// A done card with a follow-up: the follow-up's answer reads like the first one (2026-10-25).
/// The PNG goes to the temporary folder to look at.
@MainActor
struct CardFollowUpRenderTests {
    @Test func followUpAnswersLookLikeTheFirst() throws {
        let thread = [
            ChatModel.Message(role: .user, text: "what does **range** do here?"),
            ChatModel.Message(role: .assistant, text: "It counts from **0** up to `n - 1`, so the loop runs *n* times."),
        ]
        var panel = FollowUpPanel()
        _ = panel.tap(.text)
        let card = AgentDoneCard(title: "explained", summary: "", answer: "A loop that prints **each** number, using `range(n)`.",
                                 suggestions: [], tone: .idle, onClose: {}, onSuggestion: { _ in }, followUp: panel,
                                 footer: AnyView(FollowUpPanelView(panel: panel, thread: thread, onAction: { _ in })),
                                 onGoThere: {}, onLater: {})
            .frame(width: 320).padding(20).background(Color.black)
        let view = NSHostingView(rootView: card)
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.sharpRep())
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-notch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "card-followup.png"))
        #expect(view.bounds.height > 100)
    }
}
