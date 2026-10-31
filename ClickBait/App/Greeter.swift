import AppKit
import ClickBaitCore

/// Says hello by the cursor when the user comes back: watches sleep, screen sleep, session
/// activation and lock/unlock. Duplicate wake notifications are coalesced. Off in Greetings.
@MainActor
final class Greeter {
    private enum Key {
        static let lastGreeted = "greeting.lastGreeted"
        static let recent = "greeting.recent"
    }

    private let settings: AppSettings
    private let overlay: OverlayController
    private let defaults = UserDefaults.standard
    private var locked = false
    private var lastReturnEvent: Date?
    private var greetingTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private static let duplicateWakeWindow: TimeInterval = 5
    private static let retryCount = 12

    init(settings: AppSettings, overlay: OverlayController) {
        self.settings = settings
        self.overlay = overlay
    }

    /// `helloAtLaunch` is false when the notch says hello at launch instead.
    func start(helloAtLaunch: Bool) {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { greeter in
            greeter.locked = true
        }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.cameBack() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.cameBack() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { greeter in
            greeter.locked = false
            greeter.cameBack()
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { greeter in
            greeter.locked = false
            greeter.cameBack()
        }
        if helloAtLaunch {
            lastReturnEvent = Date()  // don't say hello twice if launch and wake arrive together
            greetSoon()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping @MainActor (Greeter) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self)
            }
        }
        observers.append((center, token))
    }

    private func cameBack() {
        guard !locked else { return }  // the unlock says hello
        let now = Date()
        if let lastReturnEvent, now.timeIntervalSince(lastReturnEvent) < Self.duplicateWakeWindow { return }
        lastReturnEvent = now
        greetSoon()
    }

    /// Wait for the screen to settle, then retry briefly if another companion message is up.
    private func greetSoon() {
        greetingTask?.cancel()
        greetingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            for _ in 0..<Self.retryCount {
                guard !Task.isCancelled, let self else { return }
                if self.greet() { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Returns false only when the companion is busy, so the wake task can retry.
    private func greet() -> Bool {
        guard settings.greetings else { return true }
        guard !locked else { return false }
        let now = Date()
        let period = Greeting.Period(hour: Calendar.current.component(.hour, from: now)).rawValue
        var recent = defaults.dictionary(forKey: Key.recent) as? [String: [Int]] ?? [:]
        let pick = Greeting.line(at: now, recent: recent[period] ?? [])
        guard overlay.showGreeting(pick.text) else { return false }
        recent[period] = Array(((recent[period] ?? []) + [pick.index]).suffix(Greeting.recentMemory))
        defaults.set(recent, forKey: Key.recent)
        defaults.set(now, forKey: Key.lastGreeted)
        Log.app.notice("Greeting shown")
        return true
    }
}
