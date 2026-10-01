import AppKit

/// Owns the menu bar icon and its menu. Until the overlay bubble exists (step 7),
/// the icon and the menu's first line are where ClickBait shows its state.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private static let hint = "Hold ⌃⌥ Control+Option and ask"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
    private let revealCaptureItem = NSMenuItem(title: "Reveal Last Capture", action: nil, keyEquivalent: "")
    private let settings: AppSettings
    private let onOpenSettings: () -> Void
    private let onOpenPermissions: () -> Void

    init(settings: AppSettings, onOpenSettings: @escaping () -> Void, onOpenPermissions: @escaping () -> Void) {
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        self.onOpenPermissions = onOpenPermissions
        super.init()

        statusItem.menu = makeMenu()
        update(for: .idle)
    }

    func update(for state: AskState) {
        let (symbol, line): (String, String) = switch state {
        case .idle: ("cursorarrow.rays", Self.hint)
        case .listening: ("mic.fill", "Listening…")
        case .thinking: ("ellipsis.circle", "Thinking…")
        case .speaking: ("speaker.wave.2.fill", "Speaking…")
        case .error(let message): ("exclamationmark.triangle", message)
        }
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClickBait: \(line)")
            button.image?.isTemplate = true
            button.toolTip = line
        }
        statusLine.title = line
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        revealCaptureItem.isHidden = !settings.keepDebugCaptures
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(item("Permissions…", action: #selector(openPermissions), key: ""))
        revealCaptureItem.action = #selector(revealLastCapture)
        revealCaptureItem.target = self
        menu.addItem(revealCaptureItem)
        menu.addItem(.separator())
        menu.addItem(item("About ClickBait", action: #selector(openAbout), key: ""))
        menu.addItem(item("Quit ClickBait", action: #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettings() { onOpenSettings() }
    @objc private func openPermissions() { onOpenPermissions() }

    @objc private func revealLastCapture() {
        let directory = DebugCaptureStore.directory
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSSound.beep()
        }
    }

    @objc private func openAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
