import AppKit
import ClickBaitCore
import ScriptingBridge

/// Chrome's tabs through Scripting Bridge, addressed by process id: several Chromes can run
/// under one bundle id (measured 2026-10-14: the user's, one Clicky started with no windows,
/// two automation ones), and `tell application id "com.google.Chrome"` reached a windowless
/// one. Every call is synchronous Apple Events to Chrome (the first asks the user's
/// permission and blocks until answered), so callers run it off the main thread.
enum ChromeTabs {
    /// Each window holding `point` (Quartz; every window when nil), front to back, with its
    /// showing tab.
    static func read(pid: pid_t, at point: Point?) -> [BrowserTab] {
        guard let app = SBApplication(processIdentifier: pid) else { return [] }
        var found: [BrowserTab] = []
        for window in snapshot(app.value(forKey: "windows")) {  // never the live list (see `readAll`)
            guard let id = number(window.value(forKey: "id")) else { continue }
            if let point {
                guard let bounds = rect(window.value(forKey: "bounds")),
                      point.x >= bounds.minX, point.x <= bounds.maxX, point.y >= bounds.minY, point.y <= bounds.maxY
                else { continue }
            }
            guard let tab = window.value(forKey: "activeTab") as? SBObject, let tabID = number(tab.value(forKey: "id")) else { continue }
            found.append(BrowserTab(browser: .chrome, windowID: id, tab: tabID,
                                    title: string(tab.value(forKey: "title")) ?? "", url: string(tab.value(forKey: "URL")) ?? ""))
        }
        return found
    }

    /// Every tab of every window, front window first, each window's showing tab before its others.
    static func readAll(pid: pid_t) -> [BrowserTab] {
        guard let app = SBApplication(processIdentifier: pid) else { return [] }
        var showing: [BrowserTab] = [], others: [BrowserTab] = []
        for window in snapshot(app.value(forKey: "windows")) {
            guard let id = number(window.value(forKey: "id")), let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            let active = (window.value(forKey: "activeTab") as? SBObject).flatMap { number($0.value(forKey: "id")) }
            // Each property for every tab in one request, never walking the live list: a tab
            // opened or closed mid-walk raised an exception Swift can't catch (crash, 22:46).
            let ids = (tabs.value(forKey: "id") as? [Any]) ?? []
            let titles = (tabs.value(forKey: "title") as? [Any]) ?? []
            let urls = (tabs.value(forKey: "URL") as? [Any]) ?? []
            guard ids.count == titles.count, ids.count == urls.count else { continue }  // changed between requests
            for index in ids.indices {
                guard let tabID = number(ids[index]) else { continue }
                let found = BrowserTab(browser: .chrome, windowID: id, tab: tabID,
                                       title: string(titles[index]) ?? "", url: string(urls[index]) ?? "")
                if tabID == active { showing.append(found) } else { others.append(found) }
            }
        }
        return showing + others
    }

    /// A Scripting Bridge list as plain objects, fetched in one request (`get`), so it can't
    /// change while it's being gone through.
    private static func snapshot(_ list: Any?) -> [SBObject] {
        ((list as? SBElementArray)?.get() as? [Any] ?? []).compactMap { $0 as? SBObject }
    }

    /// Runs JavaScript in the tab with this id, in this Chrome process (by process: a second,
    /// hidden Chrome can share the bundle id, and AppleScript's `tell` reached it instead).
    /// Nil when that process has no such tab or Chrome refuses (its JavaScript switch is off).
    static func execute(_ javascript: String, tabID: Int, pid: pid_t) -> String? {
        guard let app = SBApplication(processIdentifier: pid) else { return nil }
        for window in snapshot(app.value(forKey: "windows")) {
            for tab in snapshot(window.value(forKey: "tabs")) where number(tab.value(forKey: "id")) == tabID {
                let result = tab.perform(NSSelectorFromString("executeJavascript:"), with: javascript)?.takeUnretainedValue()
                return string(result) ?? (result as? NSNumber)?.stringValue
            }
        }
        return nil
    }

    /// Selects the tab (wherever it is now), brings its window to the front and Chrome
    /// forward, which switches to that window's desktop. False when the tab is gone.
    static func select(_ target: BrowserTab, pid: pid_t) -> Bool {
        guard let app = SBApplication(processIdentifier: pid) else { return false }
        for window in snapshot(app.value(forKey: "windows")) {
            for (index, tab) in snapshot(window.value(forKey: "tabs")).enumerated() {
                guard number(tab.value(forKey: "id")) == target.tab else { continue }
                window.setValue(index + 1, forKey: "activeTabIndex")
                window.setValue(1, forKey: "index")
                app.activate()
                return true
            }
        }
        return false
    }

    private static func resolved(_ value: Any?) -> Any? {
        if let object = value as? SBObject { return object.get() }
        return value
    }

    private static func number(_ value: Any?) -> Int? {
        switch resolved(value) {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    private static func string(_ value: Any?) -> String? { resolved(value) as? String }

    /// Chrome's bounds come as an NSRect of {left, top, width, height} in screen points with
    /// the origin at the top left (Quartz), as Chrome reports them.
    private static func rect(_ value: Any?) -> CGRect? {
        (resolved(value) as? NSValue)?.rectValue
    }
}
