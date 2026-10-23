import AppKit
import ApplicationServices

/// Chrome's own "Allow JavaScript from Apple Events" (View → Developer), read and flipped by
/// ClickBait through Accessibility when the user switches it in Settings (user's ask,
/// 2026-10-23: a check button that did nothing was useless). The menu item's tick is the
/// state. Only the user's Chrome: a hidden automated one can share its bundle id.
enum ChromeJavaScriptSwitch {
    static let path = ["View", "Developer", "Allow JavaScript from Apple Events"]

    /// On, off, or nil when Chrome isn't open (or its menu can't be read).
    static func isOn() async -> Bool? {
        await Task.detached(priority: .utility) {
            guard let item = menuItem() else { return nil }
            var mark: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXMenuItemMarkCharAttribute as CFString, &mark)
            return !((mark as? String) ?? "").isEmpty
        }.value
    }

    /// Clicks the menu item; true when it was pressed.
    static func toggle() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let item = menuItem() else { return false }
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }.value
    }

    private static func menuItem() -> AXUIElement? {
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
            .first(where: { $0.activationPolicy == .regular }) else { return nil }
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        guard var element: AXUIElement = value(app, kAXMenuBarAttribute) else { return nil }
        for title in path {
            // A menu bar item or menu item's children: its menu, whose children are the items.
            let containers: [AXUIElement] = value(element, kAXChildrenAttribute) ?? []
            let items = containers.flatMap { container -> [AXUIElement] in
                let role: String? = value(container, kAXRoleAttribute)
                return role == (kAXMenuRole as String) ? (value(container, kAXChildrenAttribute) ?? []) : [container]
            }
            guard let next = items.first(where: { (value($0, kAXTitleAttribute) as String?) == title }) else { return nil }
            element = next
        }
        return element
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
