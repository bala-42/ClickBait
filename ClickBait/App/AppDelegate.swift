import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplication.delegate is weak, so the delegate is kept alive here.
    private static var shared: AppDelegate?

    private var statusBar: StatusBarController?
    private lazy var settingsWindow = SettingsWindowController()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(
            onOpenSettings: { [weak self] in self?.settingsWindow.show() },
            onOpenPermissions: { [weak self] in self?.showPermissions() }
        )
    }

    private func showPermissions() {
        // Permissions onboarding arrives in step 2; until then the Settings window stands in.
        settingsWindow.show()
    }
}
