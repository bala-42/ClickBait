import AppKit
import ClickBaitCore

/// Feeds keyboard events into `ChordDetector`: hold ⌃⌥ to ask, tap ⌥⌘ to explain the
/// highlighted text. Real shortcuts that use these modifiers keep working.
///
/// Global monitors only receive events once Accessibility is granted; the local
/// monitors keep the hotkeys working while ClickBait itself is frontmost.
@MainActor
final class HotkeyMonitor {
    private let handler: (ChordDetector.Event) -> Void
    private var monitors: [Any] = []
    private var detector = ChordDetector()

    init(handler: @escaping (ChordDetector.Event) -> Void) {
        self.handler = handler
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        detector = ChordDetector()
    }

    private func handle(_ event: NSEvent) {
        let events: [ChordDetector.Event]
        switch event.type {
        case .flagsChanged:
            events = detector.modifiersChanged(to: Self.modifiers(from: event.modifierFlags))
        case .keyDown:
            events = detector.keyPressed()
        default:
            events = []
        }
        events.forEach(handler)
    }

    /// Caps Lock and Fn are ignored.
    private static func modifiers(from flags: NSEvent.ModifierFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}
