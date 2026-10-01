/// An app ClickBait must never capture, identified by bundle ID.
public struct BlockedApp: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var name: String

    public var id: String { bundleID.lowercased() }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Apps whose screens are never captured, even while the hotkey is held.
public struct AppBlocklist: Codable, Equatable, Sendable {
    public private(set) var apps: [BlockedApp]

    public init(apps: [BlockedApp]) {
        self.apps = []
        for app in apps { add(app) }
    }

    /// Password managers and keychain tools.
    public static let defaults = AppBlocklist(apps: [
        BlockedApp(bundleID: "com.apple.keychainaccess", name: "Keychain Access"),
        BlockedApp(bundleID: "com.apple.Passwords", name: "Passwords"),
        BlockedApp(bundleID: "com.1password.1password", name: "1Password"),
        BlockedApp(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        BlockedApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        BlockedApp(bundleID: "org.keepassxc.keepassxc", name: "KeePassXC"),
        BlockedApp(bundleID: "in.sinew.Enpass-Desktop", name: "Enpass"),
    ])

    /// Bundle IDs are compared case-insensitively. A missing bundle ID is not blocked.
    public func isBlocked(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let key = bundleID.lowercased()
        return apps.contains { $0.id == key }
    }

    public mutating func add(_ app: BlockedApp) {
        guard !app.bundleID.isEmpty, !isBlocked(bundleID: app.bundleID) else { return }
        apps.append(app)
    }

    public mutating func remove(bundleID: String) {
        let key = bundleID.lowercased()
        apps.removeAll { $0.id == key }
    }
}
