import AppKit
import ClickBaitCore

/// Feeds keyboard events into `ChordDetector`: hold ⌃⌥ to ask, tap ⌥⌘ to explain the
/// highlighted text, hold fn+⌃ to dictate. Real shortcuts that use these modifiers keep working.
///
/// Global monitors only receive events once Accessibility is granted; the local
/// monitors keep the hotkeys working while ClickBait itself is frontmost. A check every
/// `healthInterval` puts back a missing monitor and cancels a hold whose release never came.
@MainActor
final class HotkeyMonitor {
    private let handler: (ChordDetector.Event) -> Void
    private var monitors: [Any] = []
    private var detector = ChordDetector()
    private var health: Timer?
    /// The last check found a hold the keyboard no longer has.
    private var stale = false

    static let healthInterval = 1.5

    init(handler: @escaping (ChordDetector.Event) -> Void) {
        self.handler = handler
    }

    func start() {
        install()
        guard health == nil else { return }
        health = Timer.scheduledTimer(withTimeInterval: Self.healthInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
    }

    private func install() {
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
        health?.invalidate()
        health = nil
        stale = false
        detector = ChordDetector()
    }

    /// Adapted from Sentient OS (AGPL-3.0). A secure text field (a password box) hides key
    /// events from monitors, so a release can go missing and leave a hold stuck on. The hold is
    /// cancelled only once the keyboard has disagreed for two checks in a row, so a release
    /// still waiting in the event queue is never cut short.
    private func checkHealth() {
        if monitors.isEmpty { install() }
        guard detector.isHolding else { stale = false; return }
        let live = Self.modifiers(from: NSEvent.modifierFlags)
        var probe = detector
        guard !probe.reconcile(live: live).isEmpty else { stale = false; return }
        guard stale else { stale = true; return }
        stale = false
        Log.input.notice("Hotkey release missed; hold cancelled")
        detector.reconcile(live: live).forEach(handler)
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

    /// Caps Lock is ignored.
    private static func modifiers(from flags: NSEvent.ModifierFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }
}
