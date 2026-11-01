import Foundation

/// The exact browser tab a background job came from, for "go there!" (user's request,
/// 2026-10-14: "the right tab and the right window"). Accessibility only lists a browser's
/// windows on the current desktop (measured: Chrome's other windows, on other desktops and
/// the other display, weren't there at all), so the browser's own scripting is used: it
/// knows every window and tab, and activating it switches to the window's desktop. Chrome
/// tabs have ids that survive moving between windows; it's reached by process id through
/// Scripting Bridge in the app (`ChromeTabs`), since several Chromes can share its bundle id.
/// Safari's tabs are found by window id and index, checked against the URL, through the
/// scripts here. Pure: the Safari scripts, the parsing and the picking; the app runs them.
public struct BrowserTab: Equatable, Sendable {
    public enum Browser: String, Sendable, CaseIterable {
        case chrome = "com.google.Chrome"
        case safari = "com.apple.Safari"

        public var name: String { self == .chrome ? "Google Chrome" : "Safari" }
    }

    public let browser: Browser
    public let windowID: Int
    /// Chrome's tab id; Safari's tab index (1-based) in its window.
    public let tab: Int
    public let title: String
    public let url: String

    public init(browser: Browser, windowID: Int, tab: Int, title: String, url: String) {
        self.browser = browser
        self.windowID = windowID
        self.tab = tab
        self.title = title
        self.url = url
    }

    public static func browser(for bundleID: String?) -> Browser? {
        bundleID.flatMap(Browser.init(rawValue:))
    }

    static let separator = "\u{1F}"

    /// Safari: each window holding `point` (Quartz; any window when nil), front to back: its
    /// id and its showing tab, one per line.
    public static func safariCaptureScript(at point: Point?) -> String {
        let inside = point.map { "(\(Int($0.x)) ≥ item 1 of b and \(Int($0.x)) ≤ item 3 of b and \(Int($0.y)) ≥ item 2 of b and \(Int($0.y)) ≤ item 4 of b)" } ?? "true"
        return """
            tell application id "\(Browser.safari.rawValue)"
                set out to ""
                repeat with w in windows
                    try
                        set b to bounds of w
                        if \(inside) then
                            set t to current tab of w
                            set out to out & (id of w as text) & (character id 31) & (index of t as text) & (character id 31) & (name of t) & (character id 31) & (URL of t) & linefeed
                        end if
                    end try
                end repeat
                return out
            end tell
            """
    }

    /// Safari: every tab of every window, front to back, each window's showing tab first, in
    /// the capture script's line format (`parse`).
    public static let safariAllTabsScript = """
        tell application id "\(Browser.safari.rawValue)"
            set out to ""
            set behind to ""
            repeat with w in windows
                try
                    set c to index of current tab of w
                    repeat with t in tabs of w
                        set row to (id of w as text) & (character id 31) & (index of t as text) & (character id 31) & (name of t) & (character id 31) & (URL of t) & linefeed
                        if (index of t) is c then
                            set out to out & row
                        else
                            set behind to behind & row
                        end if
                    end repeat
                end try
            end repeat
            return out & behind
        end tell
        """

    /// The capture script's lines, front to back.
    public static func parse(_ output: String, browser: Browser) -> [BrowserTab] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.components(separatedBy: separator)
            guard fields.count == 4, let window = Int(fields[0]), let tab = Int(fields[1]) else { return nil }
            return BrowserTab(browser: browser, windowID: window, tab: tab, title: fields[2], url: fields[3])
        }
    }

    /// The one that was snipped: the front window under the circle whose page has the title
    /// accessibility saw there (windows on other desktops can share its spot), else the front one.
    public static func pick(_ tabs: [BrowserTab], title: String?) -> BrowserTab? {
        if let title, let match = tabs.first(where: { HomeWindow.tabMatches($0.title, page: title) }) { return match }
        return tabs.first
    }

    /// The site, for finding the tab again after its address changed: a YouTube playlist moves
    /// on (`&index=41`) or a timestamp is added, so the exact address no longer matches
    /// (user's report, 2026-11-01: clicking the notch's cover did nothing). nil: none.
    public var site: String? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.hasSuffix("youtube.com") ? "youtube.com/watch" : host
    }

    /// Safari: selects the tab and brings its window and Safari forward (onto that window's
    /// desktop): the same window and tab still on the same site; else the exact address
    /// anywhere; else, for YouTube, any video tab. Returns "true" when found.
    public var safariReturnScript: String {
            let url = self.url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let site = (self.site ?? self.url).replacingOccurrences(of: "\"", with: "")
            let youtube = self.site == "youtube.com/watch"
            return """
                tell application id "\(browser.rawValue)"
                    try
                        set w to window id \(windowID)
                        set u to URL of tab \(tab) of w
                        if u is "\(url)" or u contains "\(site)" then
                            set current tab of w to tab \(tab) of w
                            set index of w to 1
                            activate
                            return "true"
                        end if
                    end try
                    repeat with w in windows
                        try
                            repeat with t in tabs of w
                                if (URL of t) is "\(url)" then
                                    set current tab of w to t
                                    set index of w to 1
                                    activate
                                    return "true"
                                end if
                            end repeat
                        end try
                    end repeat
                \(youtube ? """
                    repeat with w in windows
                        try
                            repeat with t in tabs of w
                                if (URL of t) contains "youtube.com/watch" then
                                    set current tab of w to t
                                    set index of w to 1
                                    activate
                                    return "true"
                                end if
                            end repeat
                        end try
                    end repeat
                """ : "")
                    return "false"
                end tell
                """
    }
}
