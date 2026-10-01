import AppKit

/// Owns the menu bar icon and its menu.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onOpenSettings: () -> Void
    private let onOpenPermissions: () -> Void

    init(onOpenSettings: @escaping () -> Void, onOpenPermissions: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onOpenPermissions = onOpenPermissions
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "ClickBait")
            button.image?.isTemplate = true
        }
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let hint = NSMenuItem(title: "Hold ⌃⌥ Control+Option and ask", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(item("Permissions…", action: #selector(openPermissions), key: ""))
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

    @objc private func openAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
