import Foundation

/// Finding the window a background job came from among its app's windows, by the title and
/// frame it had when asked. A title match counts most (a window moved since still matches);
/// a frame match breaks ties and finds a window whose title changed (a new tab). Pure.
public enum HomeWindow {
    /// How far a frame may be off and still count as the same (rounding, a nudge).
    public static let frameSlack = 2.0

    /// The index of the best match in `windows` (front to back), or nil when none matches.
    public static func best(_ windows: [(title: String?, frame: Rect?)], title: String?, frame: Rect?) -> Int? {
        var bestIndex: Int?
        var bestScore = 0
        for (index, window) in windows.enumerated() {
            var score = 0
            if titlesMatch(window.title, title) { score += 2 }
            if let frame, let other = window.frame, sameFrame(frame, other) { score += 1 }
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Whether a window shows that title: the same once an app-name suffix (" - Google
    /// Chrome", " — Safari") is dropped and case ignored. The window list and accessibility
    /// don't always agree on the suffix.
    public static func titlesMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a = a.map(pageTitle), let b = b.map(pageTitle), !a.isEmpty, !b.isEmpty else { return false }
        return a == b
    }

    static let browsers = ["google chrome", "chrome", "safari", "firefox", "arc", "microsoft edge", "brave", "opera"]

    /// A window title as its tab is called, lowercased: everything from " - Google Chrome"
    /// (any dash, any browser) on is dropped — Chrome adds the profile after it too, e.g.
    /// "Netflix – Audio playing - Google Chrome – balaji" (read from Chrome, 2026-10-14).
    public static func pageTitle(_ title: String) -> String {
        let lowered = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var cut = lowered.endIndex
        for browser in browsers {
            for dash in [" - ", " — ", " – "] {
                if let range = lowered.range(of: dash + browser, options: .backwards), range.lowerBound > lowered.startIndex,
                   range.lowerBound < cut {
                    cut = range.lowerBound
                }
            }
        }
        return String(lowered[..<cut]).trimmingCharacters(in: .whitespaces)
    }

    /// Whether a browser tab's name is that page: the same, or one starts with the other —
    /// Chrome adds and drops status words ("Netflix – Audio playing" is "Netflix" once the
    /// sound stops). Names under 4 characters must match exactly.
    public static func tabMatches(_ name: String, page: String) -> Bool {
        let tab = pageTitle(name), page = pageTitle(page)
        guard !tab.isEmpty, !page.isEmpty else { return false }
        if tab == page { return true }
        guard min(tab.count, page.count) >= 4 else { return false }
        return tab.hasPrefix(page) || page.hasPrefix(tab)
    }

    static func sameFrame(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) <= frameSlack && abs(a.y - b.y) <= frameSlack
            && abs(a.width - b.width) <= frameSlack && abs(a.height - b.height) <= frameSlack
    }
}
