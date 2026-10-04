import AppKit
import SwiftUI

/// A panel that can take typing without activating ClickBait — like Spotlight — so
/// the app the user is asking about stays frontmost (and in the screenshots).
private final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ClickBait is a menu bar app with no Edit menu, which is what normally turns
    /// ⌘C/⌘V/… into actions — so the panel does it, sending them to the focused text
    /// field or selected answer text through the responder chain.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector? = switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "a"): #selector(NSResponder.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Owns the chat bubble window: pinned where the answer appeared, draggable, sized
/// exactly to its card, open until ✕ or Escape.
@MainActor
final class ChatController {
    let model = ChatModel()
    private var panel: NSPanel?

    var isOpen: Bool { panel != nil }

    /// `topLeft` in global AppKit points (where the companion's card was).
    func open(at topLeft: CGPoint) {
        close()
        model.messages = []
        model.draft = ""
        model.isBusy = false

        let panel = ChatPanel(
            contentRect: CGRect(x: 0, y: 0, width: ChatView.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Only take the keyboard when the text field is clicked, never on its own.
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: ChatView(model: model))

        model.onCardSizeChange = { [weak self] in self?.fitToCard() }
        self.panel = panel
        place(topLeft: topLeft)
        panel.orderFrontRegardless()
    }

    /// Opens an empty chat at `topLeft` with the cursor in the text field, ready to
    /// type. Takes the keyboard without activating ClickBait, like Spotlight.
    func openForTyping(at topLeft: CGPoint) {
        open(at: topLeft)
        panel?.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
    }

    /// Puts the cursor back in an open chat's text field.
    func focus() {
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    /// Keeps the window exactly the card's size, growing downward from a fixed top edge.
    private func fitToCard() {
        guard let panel, model.cardSize.width > 0 else { return }
        let top = panel.frame.maxY
        panel.setFrame(CGRect(x: panel.frame.minX, y: top - model.cardSize.height,
                              width: model.cardSize.width, height: model.cardSize.height), display: true)
        keepOnScreen()
    }

    private func place(topLeft: CGPoint) {
        guard let panel else { return }
        panel.setFrameTopLeftPoint(topLeft)
        keepOnScreen()
    }

    private func keepOnScreen() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}
