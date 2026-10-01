import AppKit

/// Detects Control+Option being held on its own. Pressing any other key while holding
/// cancels, so real shortcuts like ⌃⌥← keep working and don't trigger ClickBait.
///
/// Global monitors only receive events once Accessibility is granted; the local
/// monitors keep the hotkey working while ClickBait itself is frontmost.
@MainActor
final class HotkeyMonitor {
    enum Event {
        case pressed
        case released
        case cancelled
    }

    private static let hotkey: NSEvent.ModifierFlags = [.control, .option]
    /// Modifiers that count as "something else is held too". Caps Lock and Fn are ignored.
    private static let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    private let handler: (Event) -> Void
    private var monitors: [Any] = []
    private var isHeld = false

    init(handler: @escaping (Event) -> Void) {
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
        isHeld = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(Self.relevant)
            if flags == Self.hotkey {
                guard !isHeld else { return }
                isHeld = true
                handler(.pressed)
            } else if isHeld {
                isHeld = false
                // Adding ⌘ or ⇧ means the user is reaching for a different shortcut.
                handler(flags.isStrictSuperset(of: Self.hotkey) ? .cancelled : .released)
            }
        case .keyDown:
            guard isHeld else { return }
            isHeld = false
            handler(.cancelled)
        default:
            break
        }
    }
}
