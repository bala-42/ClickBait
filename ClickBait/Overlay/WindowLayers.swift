import AppKit

/// ClickBait's window layers, bottom to top, in one place (user's rule, 2026-10-14: "the
/// dock and the background spawn MUST remain on top of the notch panel"):
/// app windows < guidance (highlights, arrows) < menu bar < notch panel < dock (tiles, cards,
/// folded handle) < companion and peel flight.
enum WindowLayers {
    /// Over the apps' windows (and full-screen ones), under the menu bar and everything ClickBait's own.
    static let guidance = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    /// Just above the menu bar, where the notch is.
    static let notch = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    /// Above the notch panel, so an open notch never covers a tile, a card (confirmations,
    /// peek's result) or the AirDrop card.
    static let dock = NSWindow.Level(rawValue: notch.rawValue + 1)

    static func check() {
        assert(notch.rawValue > NSWindow.Level.mainMenu.rawValue, "the notch panel must cover the menu bar")
        assert(dock.rawValue > notch.rawValue, "the dock must stay above the notch panel")
        assert(guidance.rawValue < NSWindow.Level.mainMenu.rawValue, "guidance stays under the menu bar and ClickBait's own")
        assert(NSWindow.Level.screenSaver.rawValue > dock.rawValue, "the companion and peel flight must stay above the dock")
    }
}
