import AppKit

/// ClickBait's window layers, bottom to top, in one place (user's rule, 2026-10-14: "the
/// dock and the background spawn MUST remain on top of the notch panel"):
/// menu bar < notch panel < dock (tiles, cards, folded handle) < companion and peel flight.
enum WindowLayers {
    /// Just above the menu bar, where the notch is.
    static let notch = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    /// Above the notch panel, so an open notch never covers a tile or its card.
    static let dock = NSWindow.Level(rawValue: notch.rawValue + 1)

    static func check() {
        assert(notch.rawValue > NSWindow.Level.mainMenu.rawValue, "the notch panel must cover the menu bar")
        assert(dock.rawValue > notch.rawValue, "the dock must stay above the notch panel")
        assert(NSWindow.Level.screenSaver.rawValue > dock.rawValue, "the companion and peel flight must stay above the dock")
    }
}
