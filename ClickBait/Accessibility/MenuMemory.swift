import AppKit
import ClickBaitCore

/// Every app's menus as last read on this Mac (Application Support, one file per app). Read
/// live whenever Accessibility answers and saved; used when it doesn't. Safari, Calendar,
/// QuickTime and Numbers stopped answering for their menu bars after days running (even to
/// System Events), and walkthroughs there had no menus to plan from or point into.
enum MenuMemory {
    static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "ClickBait/Menus", directoryHint: .isDirectory)
    }()

    /// The app's menus ("History ▸ Clear History…"): live, else as remembered. Call off the main thread.
    static func outline(pid: pid_t?) -> [String] {
        guard let pid else { return [] }
        let live = AXInspector.menuOutline(frontmostPID: pid)
        guard let file = file(for: pid) else { return live }
        if !live.isEmpty {
            remember(live, in: file)
            return live
        }
        return saved(file)
    }

    /// The menu path to `label` from the remembered menus, for when Accessibility can't search
    /// the live ones (["History", "Clear History…"]).
    static func path(to label: String, pid: pid_t?) -> [String]? {
        guard let pid, let file = file(for: pid) else { return nil }
        return MenuOutline.path(to: label, in: saved(file))
    }

    /// Reads and keeps the app's menus (when it comes to the front), so they're known later.
    static func learn(pid: pid_t) {
        Task.detached(priority: .utility) { _ = outline(pid: pid) }
    }

    /// At launch: every open app's menus, one after another in the background.
    static func learnOpenApps() {
        let own = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own }.map(\.processIdentifier)
        Task.detached(priority: .background) { for pid in pids { _ = outline(pid: pid) } }
    }

    /// The remembered menus of an app that isn't running.
    static func saved(bundleID: String) -> [String] {
        saved(folder.appending(path: bundleID + ".json"))
    }

    private static func file(for pid: pid_t) -> URL? {
        guard let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier else { return nil }
        return folder.appending(path: id + ".json")
    }

    private static func saved(_ file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Merged with what's saved: a live read stops at its time budget, so each read adds to
    /// the map. Items the app has since dropped linger; harmless (a step only points at what
    /// it can find). shortcut: no version tracking, upgrade if a renamed item misleads plans.
    private static func remember(_ lines: [String], in file: URL) {
        let old = saved(file)
        let merged = lines + old.filter { !Set(lines).contains($0) }
        guard merged != old else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(merged.prefix(1_000))).write(to: file, options: .atomic)
    }
}
