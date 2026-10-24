/// How things are done on this Mac: the menu bar, Finder, the browsers and common sites.
/// Facts shipped with ClickBait, so a walkthrough starts from where things really are instead
/// of the local model's guess (it invents menu names). Names are macOS 26/27's and the
/// browsers' current ones; a target the screen doesn't show is still found by the walkthrough
/// (menus, then the screen's text) or re-planned from what is there.
///
/// Two uses: `plan(for:)` starts a matching task at once, no model; `facts(for:app:)` gives
/// the planner the nearest entries to plan anything else from.
public enum MacGuide {
    public struct Entry: Sendable {
        /// What people say ("show hidden files"), as `ImpliedPointer.normalized` writes them.
        public let phrases: [String]
        /// The app the clicks happen in; nil for the menu bar and system shortcuts (any app).
        public let app: String?
        /// (what to click or press, what to tell the user).
        public let steps: [(target: String, instruction: String)]
    }

    /// The walkthrough for a request the guide knows; the longest matching phrase wins, and
    /// between equals the one for `app` (the app in front): "reopen closed tab" in Chrome.
    /// `outline`: the app's menus, to pick the spelling this Mac uses where names differ by
    /// language ("Empty Trash…|Empty Bin…": British English says Bin).
    public static func plan(for request: String, app: String? = nil, outline: [String] = []) -> TutorialPlan? {
        guard let entry = entry(for: request, app: app) else { return nil }
        let names = Set(outline.flatMap { $0.components(separatedBy: " ▸ ") })
        let steps = entry.steps.map { step -> TutorialStep in
            let variants = step.target.components(separatedBy: "|")
            let target = variants.first(where: names.contains) ?? variants[0]
            let instruction = variants.count > 1 ? "Choose \(target)" : step.instruction
            return TutorialStep(target: target, instruction: instruction, app: entry.app)
        }
        let place = entry.app.map { " in \($0)" } ?? ""
        return TutorialPlan(intro: "Here's how\(place).", steps: steps)
    }

    static func entry(for request: String, app: String? = nil) -> Entry? {
        let spoken = " " + ImpliedPointer.normalized(request) + " "
        let front = app?.lowercased()
        var best: (length: Int, here: Bool, entry: Entry)?
        for entry in entries {
            let here = entry.app?.lowercased() == front
            for phrase in entry.phrases where spoken.contains(" " + phrase + " ") {
                guard let current = best else { best = (phrase.count, here, entry); continue }
                if phrase.count > current.length || (phrase.count == current.length && here && !current.here) {
                    best = (phrase.count, here, entry)
                }
            }
        }
        return best?.entry
    }

    /// What the planner should know for this request: entries sharing its words (in `app`
    /// first), then that app's or site's notes. At most `limit` lines.
    public static func facts(for request: String, app: String?, limit: Int = 8) -> [String] {
        let words = Set(ImpliedPointer.normalized(request).split(separator: " ").filter { $0.count >= 4 }.map(String.init))
        let lowerApp = app?.lowercased()
        let scored = entries.compactMap { entry -> (Int, String)? in
            let shared = entry.phrases.map { phrase in phrase.split(separator: " ").filter { words.contains(String($0)) }.count }.max() ?? 0
            guard shared > 0 else { return nil }
            let path = entry.steps.map { $0.target.replacingOccurrences(of: "|", with: " or ") }.joined(separator: " → ")
            let bonus = entry.app?.lowercased() == lowerApp ? 1 : 0
            return (shared * 2 + bonus, "\(entry.app ?? "Any app"): \(entry.phrases[0]) — \(path)")
        }
        var lines = scored.sorted { $0.0 > $1.0 }.map(\.1)
        let spoken = " " + ImpliedPointer.normalized(request) + " "
        for (names, notes) in placeNotes where names.contains(where: { $0 == lowerApp || spoken.contains(" " + $0 + " ") }) {
            lines += notes
        }
        return Array(lines.prefix(limit))
    }

    // MARK: - The guide

    static let entries: [Entry] = menuBar + finder + safari + chrome

    /// The menu bar's right side and the Apple menu: the same from every app.
    static let menuBar: [Entry] = [
        Entry(phrases: ["control center", "control centre"], app: nil,
              steps: [("Control Center", "Click Control Center in the menu bar")]),
        Entry(phrases: ["screen mirroring", "mirror my screen", "airplay my screen"], app: nil,
              steps: [("Control Center", "Click Control Center in the menu bar"), ("Screen Mirroring", "Click Screen Mirroring")]),
        Entry(phrases: ["focus mode", "turn on focus", "do not disturb on", "turn on do not disturb"], app: nil,
              steps: [("Control Center", "Click Control Center in the menu bar"), ("Focus", "Click Focus")]),
        Entry(phrases: ["notification center", "notification centre", "see my notifications", "widgets"], app: nil,
              steps: [("Clock", "Click the date and time at the right of the menu bar")]),
        Entry(phrases: ["spotlight", "search my mac", "open spotlight"], app: nil,
              steps: [("⌘Space", "Press ⌘Space to open Spotlight")]),
        Entry(phrases: ["emoji", "emoji picker", "insert an emoji", "type an emoji"], app: nil,
              steps: [("⌃⌘Space", "Press ⌃⌘Space for emoji")]),
        Entry(phrases: ["take a screenshot", "screenshot", "screen recording", "record my screen"], app: nil,
              steps: [("⌘⇧5", "Press ⌘⇧5 for the screenshot tools")]),
        Entry(phrases: ["force quit", "force quit an app", "app is frozen", "app not responding"], app: nil,
              steps: [("Apple", "Open the Apple menu"), ("Force Quit…", "Choose Force Quit…")]),
        Entry(phrases: ["about this mac", "which mac do i have", "my mac model", "macos version", "what version of macos"], app: nil,
              steps: [("Apple", "Open the Apple menu"), ("About This Mac", "Choose About This Mac")]),
        Entry(phrases: ["restart my mac", "restart the mac", "reboot"], app: nil,
              steps: [("Apple", "Open the Apple menu"), ("Restart…", "Choose Restart…")]),
        Entry(phrases: ["shut down", "shutdown", "turn off my mac", "power off"], app: nil,
              steps: [("Apple", "Open the Apple menu"), ("Shut Down…", "Choose Shut Down…")]),
        Entry(phrases: ["sleep my mac", "put my mac to sleep", "put the mac to sleep"], app: nil,
              steps: [("Apple", "Open the Apple menu"), ("Sleep", "Choose Sleep")]),
        Entry(phrases: ["lock my screen", "lock the screen", "lock my mac"], app: nil,
              steps: [("Apple", "Open the Apple menu"), ("Lock Screen", "Choose Lock Screen")]),
        Entry(phrases: ["recent items", "recently opened"], app: nil,
              steps: [("Apple", "Open the Apple menu"), ("Recent Items", "Open Recent Items")]),
        Entry(phrases: ["app store", "update my apps"], app: nil,
              steps: [("Apple", "Open the Apple menu"), ("App Store…", "Choose App Store…")]),
    ]

    static let finder: [Entry] = [
        Entry(phrases: ["show hidden files", "hidden files", "see hidden files"], app: "Finder",
              steps: [("⌘⇧.", "Press ⌘⇧. to show or hide hidden files")]),
        Entry(phrases: ["new folder", "make a folder", "create a folder"], app: "Finder",
              steps: [("File", "Open the File menu"), ("New Folder", "Choose New Folder")]),
        Entry(phrases: ["new finder window"], app: "Finder",
              steps: [("File", "Open the File menu"), ("New Finder Window", "Choose New Finder Window")]),
        Entry(phrases: ["get info", "file size", "folder size", "file info"], app: "Finder",
              steps: [("File", "Open the File menu"), ("Get Info", "Choose Get Info")]),
        Entry(phrases: ["go to folder", "open a path", "type a path"], app: "Finder",
              steps: [("Go", "Open the Go menu"), ("Go to Folder…", "Choose Go to Folder…")]),
        Entry(phrases: ["connect to server", "connect to a server", "network drive", "smb"], app: "Finder",
              steps: [("Go", "Open the Go menu"), ("Connect to Server…", "Choose Connect to Server…")]),
        Entry(phrases: ["airdrop"], app: "Finder",
              steps: [("Go", "Open the Go menu"), ("AirDrop", "Choose AirDrop")]),
        Entry(phrases: ["my downloads", "downloads folder", "find my downloads", "open downloads"], app: "Finder",
              steps: [("Go", "Open the Go menu"), ("Downloads", "Choose Downloads")]),
        Entry(phrases: ["applications folder", "my applications", "all my apps"], app: "Finder",
              steps: [("Go", "Open the Go menu"), ("Applications", "Choose Applications")]),
        Entry(phrases: ["documents folder", "my documents"], app: "Finder",
              steps: [("Go", "Open the Go menu"), ("Documents", "Choose Documents")]),
        Entry(phrases: ["desktop folder"], app: "Finder",
              steps: [("Go", "Open the Go menu"), ("Desktop", "Choose Desktop")]),
        Entry(phrases: ["home folder", "user folder"], app: "Finder",
              steps: [("Go", "Open the Go menu"), ("Home", "Choose Home")]),
        Entry(phrases: ["utilities folder", "activity monitor", "disk utility"], app: "Finder",
              steps: [("Go", "Open the Go menu"), ("Utilities", "Choose Utilities")]),
        Entry(phrases: ["empty the trash", "empty trash", "empty bin", "empty the bin"], app: "Finder",
              steps: [("Finder", "Open the Finder menu"), ("Empty Trash…|Empty Bin…", "Choose Empty Trash…")]),
        Entry(phrases: ["path bar", "show the path", "see the file path"], app: "Finder",
              steps: [("View", "Open the View menu"), ("Show Path Bar", "Choose Show Path Bar")]),
        Entry(phrases: ["status bar", "free space"], app: "Finder",
              steps: [("View", "Open the View menu"), ("Show Status Bar", "Choose Show Status Bar")]),
        Entry(phrases: ["file extensions", "show extensions", "filename extensions"], app: "Finder",
              steps: [("Finder", "Open the Finder menu"), ("Settings…", "Choose Settings…"), ("Advanced", "Click Advanced"),
                      ("Show all filename extensions", "Tick Show all filename extensions")]),
    ]

    static let safari: [Entry] = [
        Entry(phrases: ["safari history", "clear safari history", "clear history in safari"], app: "Safari",
              steps: [("History", "Open the History menu"), ("Clear History…", "Choose Clear History…")]),
        Entry(phrases: ["safari private window", "private window", "private browsing"], app: "Safari",
              steps: [("File", "Open the File menu"), ("New Private Window", "Choose New Private Window")]),
        Entry(phrases: ["safari extensions"], app: "Safari",
              steps: [("Safari", "Open the Safari menu"), ("Settings…", "Choose Settings…"), ("Extensions", "Click Extensions")]),
        Entry(phrases: ["safari downloads"], app: "Safari",
              steps: [("View", "Open the View menu"), ("Show Downloads", "Choose Show Downloads")]),
        Entry(phrases: ["safari search engine", "change search engine", "default search engine"], app: "Safari",
              steps: [("Safari", "Open the Safari menu"), ("Settings…", "Choose Settings…"), ("Search", "Click Search")]),
        Entry(phrases: ["safari reader", "reader mode", "reader view"], app: "Safari",
              steps: [("View", "Open the View menu"), ("Show Reader", "Choose Show Reader")]),
        Entry(phrases: ["reopen closed tab", "reopen the last tab", "undo close tab"], app: "Safari",
              steps: [("History", "Open the History menu"), ("Reopen Last Closed Tab", "Choose Reopen Last Closed Tab")]),
        Entry(phrases: ["safari bookmarks", "show bookmarks"], app: "Safari",
              steps: [("Bookmarks", "Open the Bookmarks menu"), ("Show Bookmarks", "Choose Show Bookmarks")]),
    ]

    static let chrome: [Entry] = [
        Entry(phrases: ["chrome history", "clear chrome history", "delete browsing data", "clear browsing data"], app: "Google Chrome",
              steps: [("Chrome", "Open the Chrome menu"), ("Delete browsing data…", "Choose Delete browsing data…")]),
        Entry(phrases: ["incognito", "incognito window", "private window", "private browsing"], app: "Google Chrome",
              steps: [("File", "Open the File menu"), ("New Incognito window", "Choose New Incognito window")]),
        Entry(phrases: ["reopen closed tab", "reopen the last tab", "undo close tab"], app: "Google Chrome",
              steps: [("File", "Open the File menu"), ("Re-open Closed Tab", "Choose Re-open Closed Tab")]),
        Entry(phrases: ["chrome extensions"], app: "Google Chrome",
              steps: [("Window", "Open the Window menu"), ("Extensions", "Choose Extensions")]),
        Entry(phrases: ["chrome downloads"], app: "Google Chrome",
              steps: [("Window", "Open the Window menu"), ("Downloads", "Choose Downloads")]),
        Entry(phrases: ["chrome bookmarks", "bookmark manager"], app: "Google Chrome",
              steps: [("Bookmarks", "Open the Bookmarks menu"), ("Open bookmark manager", "Choose Open bookmark manager")]),
        Entry(phrases: ["full history", "chrome full history"], app: "Google Chrome",
              steps: [("History", "Open the History menu"), ("Show Full History", "Choose Show Full History")]),
    ]

    /// How an app's or a site's window is laid out, for the planner (no fixed steps).
    static let placeNotes: [([String], [String])] = [
        (["safari"], ["Safari: the address and search field is at the top of the window; tabs sit beside or under it"]),
        (["google chrome", "chrome"], ["Chrome: the address bar is at the top; the ⋮ menu at its far right holds History, Downloads, Extensions and Settings"]),
        (["finder"], ["Finder: the sidebar on the left lists Favorites (Desktop, Downloads, Documents, Applications) and Locations"]),
        (["system settings"], ["System Settings: pages are listed in the sidebar on the left; a search field sits at its top"]),
        (["youtube"], ["YouTube: the search box is at the top centre; History, Subscriptions and Watch later are in the left sidebar (☰ opens it)",
                       "YouTube: a video's Like, Share and Save are under the player"]),
        (["google"], ["Google: the search box is in the middle; the account picture and the apps grid are at the top right"]),
        (["gmail"], ["Gmail: Compose is at the top left; search mail is at the top; folders (Inbox, Sent, Drafts) are in the left column"]),
        (["menu bar"], ["Menu bar: the Apple menu is at the far left, then the front app's menus; at the right, status icons, Control Center, then the date and time (Notification Center)"]),
    ]
}
