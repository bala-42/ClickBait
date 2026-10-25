import AppKit
import ClickBaitCore
import SwiftUI

/// The shelf's note as a real text view (user's ask, 2026-10-25), for lists that behave as in
/// Notes (`NoteEditing`): Return carries a list on, Tab and ⇧Tab indent, a click on ☐ ticks
/// it, text or a link dropped on it lands on a new line. Edits go through the text system,
/// so ⌘Z undoes them.
struct NoteTextView: NSViewRepresentable {
    @Bindable var note: NotchController.Note
    let onFocus: (Bool) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let box = NoteTextBox()
        box.delegate = context.coordinator
        box.onFocus = onFocus
        box.drawsBackground = false
        box.isRichText = false
        box.allowsUndo = true
        box.font = .systemFont(ofSize: 13)
        box.textColor = NSColor(NotchPalette.text)
        box.insertionPointColor = NSColor(NotchPalette.highlight)
        box.textContainerInset = NSSize(width: 0, height: 2)
        box.textContainer?.lineFragmentPadding = 5
        box.isAutomaticQuoteSubstitutionEnabled = false
        box.isAutomaticDashSubstitutionEnabled = false
        box.isVerticallyResizable = true
        box.autoresizingMask = [.width]
        box.textContainer?.widthTracksTextView = true
        box.registerForDraggedTypes([.string, .URL])
        box.string = note.text
        box.setAccessibilityLabel("Quick note")
        scroll.documentView = box
        note.textView = box
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let box = scroll.documentView as? NoteTextBox, box.string != note.text else { return }
        box.string = note.text  // changed elsewhere (clear, a drop, dictation)
    }

    func makeCoordinator() -> Coordinator { Coordinator(note: note) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let note: NotchController.Note
        init(note: NotchController.Note) { self.note = note }

        func textDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSTextView, note.text != box.string else { return }
            note.text = box.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let box = textView as? NoteTextBox else { return false }
            let caret = box.selectedRange().location
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard let edit = NoteEditing.newline(in: box.string, at: caret) else { return false }
                box.apply(edit)
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                guard let edit = NoteEditing.indent(in: box.string, at: caret, outdent: selector == #selector(NSResponder.insertBacktab(_:))) else {
                    return false
                }
                box.apply(edit)
            default:
                return false
            }
            return true
        }
    }
}

/// The note's text view: ticks boxes on click, adds drops on a new line.
final class NoteTextBox: NSTextView {
    var onFocus: (Bool) -> Void = { _ in }

    /// Replaces the whole text through the text system (undoable), the caret at `edit.caret`.
    func apply(_ edit: NoteEditing.Edit) {
        replaceAll(with: edit.text)
        setSelectedRange(NSRange(location: min(edit.caret, (string as NSString).length), length: 0))
    }

    func replaceAll(with text: String) {
        let all = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: all, replacementString: text) else { return }
        replaceCharacters(in: all, with: text)
        didChangeText()
    }

    /// Text at the caret (dictation), on its own line's end when nothing is selected.
    func insertAtCaret(_ text: String) {
        window?.makeFirstResponder(self)
        insertText(text, replacementRange: selectedRange())
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        // The box is the character the click lands on or just before.
        for candidate in [index, index - 1] {
            if let ticked = NoteEditing.tick(in: string, at: candidate) {
                let caret = selectedRange()
                replaceAll(with: ticked)
                setSelectedRange(caret)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus(false) }
        return resigned
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let dropped = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL])?
            .map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n")
            ?? board.string(forType: .string)
        guard let dropped, !dropped.isEmpty else { return super.performDragOperation(sender) }
        replaceAll(with: NoteEditing.adding(dropped, to: string))
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        return true
    }
}
