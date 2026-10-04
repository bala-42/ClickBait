/// Where common settings live in System Settings: the sidebar page, then what to click
/// on it. Facts, not guesses — the local model sent "Night Shift" to General, then
/// invented "Built-in Display → Touch". Page names are macOS 26/27's (checked against
/// System Settings' own extensions, which also list paths like "Displays → Night Shift").
/// Anything not here is still planned by the model once System Settings is open.
public enum SystemSettingsMap {
    /// The clicks inside System Settings for this request (["Displays", "Night Shift"]),
    /// or nil when it names no setting the map knows. The longest matching phrase wins
    /// ("keyboard brightness" → Keyboard, not Displays).
    public static func route(for text: String) -> [String]? {
        let spoken = " " + ImpliedPointer.normalized(text) + " "
        var best: (phrase: String, path: [String])?
        for (phrases, path) in routes {
            for phrase in phrases where spoken.contains(" " + phrase + " ") && phrase.count > (best?.phrase.count ?? 0) {
                best = (phrase, path)
            }
        }
        return best?.path
    }

    /// Phrases as `ImpliedPointer.normalized` writes them (lowercase, punctuation → space).
    static let routes: [([String], [String])] = [
        (["night shift"], ["Displays", "Night Shift"]),
        (["true tone"], ["Displays", "True Tone"]),
        (["brightness", "screen brightness", "refresh rate", "resolution", "screen resolution", "display resolution",
          "external display", "second display", "displays", "display settings"], ["Displays"]),
        (["wallpaper", "desktop background", "desktop picture", "screen saver", "screensaver"], ["Wallpaper"]),
        (["dark mode", "light mode", "appearance", "accent color", "accent colour", "highlight color"], ["Appearance"]),
        (["bluetooth"], ["Bluetooth"]),
        (["wi fi", "wifi"], ["Wi‑Fi"]),
        (["network settings", "firewall"], ["Network"]),
        (["vpn"], ["VPN"]),
        (["sound output", "sound input", "output device", "input device", "alert sound", "alert volume", "startup sound"], ["Sound"]),
        (["notifications", "notification settings"], ["Notifications"]),
        (["focus mode", "focus modes", "do not disturb"], ["Focus"]),
        (["battery", "low power mode", "energy saver"], ["Battery"]),
        (["battery percentage", "menu bar", "control center", "control centre"], ["Menu Bar"]),
        (["trackpad", "tap to click", "scroll direction", "tracking speed"], ["Trackpad"]),
        (["mouse speed", "mouse settings"], ["Mouse"]),
        (["key repeat", "keyboard settings", "keyboard brightness", "keyboard backlight", "input source", "input sources",
          "keyboard layout"], ["Keyboard"]),
        (["desktop and dock", "hide the dock", "dock size", "dock position", "dock magnification", "stage manager",
          "mission control", "default browser"], ["Desktop & Dock"]),
        (["hot corners"], ["Desktop & Dock", "Hot Corners…"]),
        (["lock screen"], ["Lock Screen"]),
        (["login password", "touch id"], ["Touch ID & Password"]),
        (["privacy settings", "location services", "filevault"], ["Privacy & Security"]),
        (["screen time"], ["Screen Time"]),
        (["family sharing"], ["Family"]),
        (["printers", "add a printer"], ["Printers & Scanners"]),
        (["accessibility", "voiceover", "cursor size", "pointer size"], ["Accessibility"]),
        (["user account", "user accounts", "guest user"], ["Users & Groups"]),
        // Under General.
        (["software update", "macos update", "update macos", "update my mac"], ["General", "Software Update"]),
        (["storage"], ["General", "Storage"]),
        (["file sharing", "screen sharing"], ["General", "Sharing"]),
        (["login items"], ["General", "Login Items"]),
        (["time machine"], ["General", "Time Machine"]),
        (["date and time", "date time", "time zone"], ["General", "Date & Time"]),
        (["system language", "preferred language", "region settings"], ["General", "Language & Region"]),
        (["startup disk"], ["General", "Startup Disk"]),
    ]
}
