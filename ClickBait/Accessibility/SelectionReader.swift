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

    /// `beforeCopy` runs before the ⌘C fallback; false skips it (a double tap of ⌥⌘ came:
    /// it needs no selection).
    static func read(frontmostPID: pid_t?, accessibilitySelection: String?,
                     beforeCopy: () async -> Bool = { true }) async -> (text: String, method: Method)? {
        if let text = accessibilitySelection?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return (text, .accessibility)
        }
        guard await beforeCopy() else { return nil }
        // Nothing highlighted, the app's Copy is greyed out, and a ⌘C sent to it makes macOS
        // play its alert sound (heard on every ⌥⌘ double tap, 2026-10-12): don't send it.
        if let pid = frontmostPID {
            let enabled = await Task.detached(priority: .userInitiated) { copyIsEnabled(pid: pid) }.value
            if enabled == false {
                Log.ask.notice("Explain: the app's Copy is disabled, so nothing is highlighted; no ⌘C sent")
                return nil
            }
        }
        guard let text = await copySelection(), !text.isEmpty else { return nil }
        return (text, .copy)
    }

    /// Whether the app's ⌘C menu item (Edit ▸ Copy, found by its shortcut) is enabled: nil
    /// if it has no such item Accessibility can read (then ⌘C is tried as before).
    nonisolated static func copyIsEnabled(pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
            return value as? [AXUIElement] ?? []
        }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        guard let menuBarValue = attribute(app, kAXMenuBarAttribute),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return nil }
        let menuBar = unsafeDowncast(menuBarValue, to: AXUIElement.self)  // its type checked just above
        for title in children(menuBar).prefix(12) {
            for menu in children(title) {
                for item in children(menu).prefix(60) {
                    guard (attribute(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "C",
                          (attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0 else { continue }  // 0 = ⌘ alone
                    return attribute(item, kAXEnabledAttribute) as? Bool
                }
            }
        }
        return nil
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
