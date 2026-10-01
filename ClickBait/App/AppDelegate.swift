import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplication.delegate is weak, so the delegate is kept alive here.
    private static var shared: AppDelegate?

    private let permissions = PermissionsManager()
    private var statusBar: StatusBarController?
    private lazy var settingsWindow = SettingsWindowController()
    private lazy var onboardingWindow = OnboardingWindowController(permissions: permissions)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherInstances()

        statusBar = StatusBarController(
            onOpenSettings: { [weak self] in self?.settingsWindow.show() },
            onOpenPermissions: { [weak self] in self?.onboardingWindow.show() }
        )

        if onboardingWindow.shouldShowAtLaunch {
            onboardingWindow.show()
        }
    }

    /// Two copies would mean two menu bar icons and two hotkey listeners. The newest
    /// launch wins, so Xcode's ⌘R replaces an already-running build.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != currentPID {
            app.terminate()
        }
    }
}
