import Foundation

/// What an app leaves in ~/Library (user's ask, 2026-11-02, after Vorssaint's Uninstaller):
/// the places named after its bundle identifier, and — only for a distinctive name — after its
/// name. Never Apple's apps, apps in /System, or ClickBait. Everything found goes to the Trash,
/// after asking.
public enum AppLeftovers {
    /// Paths inside ~/Library to look at.
    public static func places(bundleID: String, name: String) -> [String] {
        var places = ["Application Support/\(bundleID)", "Caches/\(bundleID)", "Containers/\(bundleID)",
                      "Saved Application State/\(bundleID).savedState", "Preferences/\(bundleID).plist",
                      "HTTPStorages/\(bundleID)", "HTTPStorages/\(bundleID).binarycookies", "WebKit/\(bundleID)",
                      "Cookies/\(bundleID).binarycookies", "Logs/\(bundleID)", "Application Scripts/\(bundleID)"]
        if distinctive(name) { places += ["Application Support/\(name)", "Caches/\(name)", "Logs/\(name)"] }
        return places
    }

    /// Folders whose entries are the app's when they carry its bundle identifier.
    public static let scanned = ["Preferences/ByHost", "LaunchAgents", "Group Containers"]

    public static func belongs(_ entry: String, bundleID: String) -> Bool {
        entry.hasPrefix(bundleID + ".") || entry == bundleID || entry.hasSuffix("." + bundleID) || entry.hasPrefix(bundleID)
    }

    /// Whether an app may be taken out at all.
    public static func removable(bundleID: String?, path: String) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return !path.hasPrefix("/System/") && !bundleID.hasPrefix("com.apple.") && bundleID != "org.clickbait.ClickBait"
    }

    /// A name that can't be some other app's folder: four letters or more, not a common word.
    static func distinctive(_ name: String) -> Bool {
        name.count >= 4 && !["Helper", "Update", "Updater", "Library", "Support", "Shared", "Default"].contains(name)
    }
}
