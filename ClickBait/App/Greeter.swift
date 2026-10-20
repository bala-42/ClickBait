import AppKit
import ClickBaitCore

/// Says hello by the cursor when the user comes back (`Greeting`): watches sleep, screen
/// sleep and lock to know when they left, and wake or unlock to know they're back. A wake
/// while the screen is still locked waits for the unlock. Off in the menu (Greetings).
@MainActor
final class Greeter {
    private enum Key {
        static let lastGreeted = "greeting.lastGreeted"
        static let recent = "greeting.recent"
    }

    private let settings: AppSettings
    private let overlay: OverlayController
    private let defaults = UserDefaults.standard
    private var awaySince: Date?
    private var locked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(settings: AppSettings, overlay: OverlayController) {
        self.settings = settings
        self.overlay = overlay
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.willSleepNotification) { $0.left() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.left() }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { greeter in
            greeter.locked = true
            greeter.left()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.cameBack() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.cameBack() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { greeter in
            greeter.locked = false
            greeter.cameBack()
        }
        greetSoon()  // launched at login, or for the first time today
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

    private func left() {
        if awaySince == nil { awaySince = Date() }
    }

    private func cameBack() {
        guard !locked else { return }  // the unlock says hello
        greetSoon()
    }

    /// After the screen has settled; the time away counts from when they left.
    private func greetSoon() {
        let away = awaySince
        awaySince = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.greet(awaySince: away)
        }
    }

    private func greet(awaySince: Date?) {
        let now = Date()
        let lastGreeted = defaults.object(forKey: Key.lastGreeted) as? Date
        guard settings.greetings, !locked,
              Greeting.shouldGreet(now: now, awaySince: awaySince, lastGreeted: lastGreeted) else { return }
        let period = Greeting.Period(hour: Calendar.current.component(.hour, from: now)).rawValue
        var recent = defaults.dictionary(forKey: Key.recent) as? [String: [Int]] ?? [:]
        let pick = Greeting.line(at: now, recent: recent[period] ?? [])
        guard overlay.showGreeting(pick.text) else { return }  // busy: no hello this time
        recent[period] = Array(((recent[period] ?? []) + [pick.index]).suffix(Greeting.recentMemory))
        defaults.set(recent, forKey: Key.recent)
        defaults.set(now, forKey: Key.lastGreeted)
        Log.app.notice("Greeting shown")
    }
}
