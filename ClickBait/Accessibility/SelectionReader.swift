import AppKit
import Carbon.HIToolbox

/// Gets the text the user highlighted in the frontmost app.
///
/// Accessibility first (no side effects). Some apps don't expose their selection that
/// way, so the fallback asks the app to copy it (⌘C) and then puts the clipboard back
/// exactly as it was — every item and type, not just text.
@MainActor
enum SelectionReader {
    enum Method: String {
        case accessibility
        case copy
    }

    static func read(frontmostPID: pid_t?, accessibilitySelection: String?) async -> (text: String, method: Method)? {
        if let text = accessibilitySelection?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return (text, .accessibility)
        }
        guard let text = await copySelection(), !text.isEmpty else { return nil }
        return (text, .copy)
    }

    private static func copySelection() async -> String? {
        // ⌥⌘ fires when the first key comes up; wait for the other so the app sees a
        // plain ⌘C, not ⌥⌘C.
        let releaseDeadline = ContinuousClock.now + .seconds(1)
        while !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            guard ContinuousClock.now < releaseDeadline else { return nil }
            try? await Task.sleep(for: .milliseconds(15))
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        let before = pasteboard.changeCount

        postCommandC()

        // Apps copy asynchronously; give them a moment.
        let copyDeadline = ContinuousClock.now + .milliseconds(500)
        while pasteboard.changeCount == before, ContinuousClock.now < copyDeadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard pasteboard.changeCount != before else { return nil }  // nothing was selected

        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        restore(saved, to: pasteboard)
        return text
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let key = CGKeyCode(kVK_ANSI_C)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
