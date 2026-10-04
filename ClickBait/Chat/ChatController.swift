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
    /// The companion's point now (AppKit): the card shrinks back into it on closing.
    var companionPoint: (() -> CGPoint)?
    /// Where the companion was when the chat opened.
    private var origin: CGPoint?

    /// `topLeft` in global AppKit points (where the companion's card was).
    func open(at topLeft: CGPoint) {
        closeNow()
        model.messages = []
        model.draft = ""
        model.isBusy = false
        model.isClosing = false

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
        origin = companionPoint?() ?? topLeft
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

    /// Shrinks back into the companion, then goes.
    func close() {
        guard let closing = panel else { return }
        aim(at: companionPoint?() ?? NSEvent.mouseLocation, in: closing.frame)
        model.isClosing = true
        panel = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))  // the shrink (0.18 s) plays out
            closing.orderOut(nil)
            closing.close()
        }
    }

    private func closeNow() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    /// Keeps the window exactly the card's size, growing downward from a fixed top edge.
    private func fitToCard() {
        guard let panel, model.cardSize.width > 0 else { return }
        let size = CGSize(width: model.cardSize.width.rounded(.up), height: model.cardSize.height.rounded(.up))
        guard size != panel.frame.size else { return }  // a resize forces a redraw: only when it changed
        let top = panel.frame.maxY
        panel.setFrame(CGRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        keepOnScreen()
        if let origin, !model.isClosing { aim(at: origin, in: panel.frame) }
    }

    private func place(topLeft: CGPoint) {
        guard let panel else { return }
        panel.setFrameTopLeftPoint(topLeft)
        keepOnScreen()
    }

    /// Points the grow/shrink animation at `point` (the companion), wherever the card
    /// ended up (it's pushed back on screen near edges).
    private func aim(at point: CGPoint, in frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let x = min(max((point.x - frame.minX) / frame.width, 0), 1)
        let y = min(max((frame.maxY - point.y) / frame.height, 0), 1)
        model.companionAnchor = UnitPoint(x: x, y: y)
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
