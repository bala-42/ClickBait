import AppKit
import ApplicationServices
import os
import ClickBaitCore

/// What the accessibility API says about the frontmost app when the hotkey is pressed.
struct AXSnapshot: Sendable {
    var windowTitle: String?
    var windowFrame: Rect?
    /// e.g. `AXTextField "Search"`.
    var focusedElement: String?
    /// Text highlighted in the focused element, if the app exposes it.
    var selectedText: String?
}

/// Reads the accessibility tree. Every call here is synchronous IPC to another app, so
/// callers run it off the main thread, and each element gets a short timeout so a
/// hung app can't stall ClickBait. Without Accessibility permission everything
/// returns empty and ClickBait simply doesn't snap.
enum AXInspector {
    /// An app's accessibility root. ClickBait's own, asked off the main thread, is an
    /// element that answers nothing: AppKit builds its menus and text fields on the asking
    /// thread, and off the main thread that threw (NSMenu assertion) and left SwiftUI's lock
    /// held, freezing ClickBait for good. Since it became a regular app it's often the app in
    /// front when a question is asked (deadlock, 2026-10-25).
    nonisolated static func appElement(_ pid: pid_t) -> AXUIElement {
        if pid == getpid(), !Thread.isMainThread { return AXUIElementCreateApplication(0) }
        return AXUIElementCreateApplication(pid)
    }

    private static let timeout: Float = 0.15

    static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - Context

    static func snapshot(frontmostPID: pid_t?) -> AXSnapshot {
        guard isTrusted else { return AXSnapshot() }
        var result = AXSnapshot()

        if let pid = frontmostPID {
            let app = element(appElement(pid))
            if let window = app.element(kAXFocusedWindowAttribute) {
                result.windowTitle = window.string(kAXTitleAttribute)
                result.windowFrame = window.frame
            }
        }

        let systemWide = element(AXUIElementCreateSystemWide())
        // Some apps only answer "what's focused" when asked directly.
        let focused = systemWide.element(kAXFocusedUIElementAttribute)
            ?? frontmostPID.flatMap { element(appElement($0)).element(kAXFocusedUIElementAttribute) }
        if let focused {
            let role = focused.string(kAXRoleAttribute) ?? "element"
            let name = focused.name
            result.focusedElement = name.isEmpty ? role : "\(role) “\(name)”"
            result.selectedText = selectedText(around: focused)
        }
        return result
    }

    /// The highlighted text, looked up on the focused element and its ancestors: plain
    /// `AXSelectedText` (native text views), then WebKit/Chromium text markers (web
    /// content, where the focused element is often a container of the selection).
    private static func selectedText(around focused: AXElement) -> String? {
        var current: AXElement? = focused
        for _ in 0..<6 {
            guard let element = current else { break }
            if let text = element.string(kAXSelectedTextAttribute), !text.isEmpty { return text }
            if let text = element.selectedTextViaMarkers(), !text.isEmpty { return text }
            current = element.element(kAXParentAttribute)
        }
        return nil
    }

    // MARK: - Element list

    /// Chromium-based browsers and Electron apps (Chrome, Slack, VS Code, Discord…) keep
    /// their accessibility tree off unless an assistive app asks for it, so their buttons
    /// and links are invisible to the element list. `AXManualAccessibility` is the
    /// switch they provide for exactly this; other apps ignore it. Nothing is changed
    /// on the Mac, and the app forgets it when it quits.
    static func requestAccessibilityTree(pid: pid_t?) {
        guard isTrusted, let pid else { return }
        let app = appElement(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result == .success, requestedTrees.withLock({ $0.insert(pid).inserted }) {
            Log.ask.notice("Asked the frontmost app to build its accessibility tree")
        }
    }

    /// Apps already asked (only to log once per app).
    private static let requestedTrees = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    /// Roles worth offering to the model as something to point at.
    private static let listedRoles = Snapper.actionableRoles.union(["AXRow"])
    /// Containers whose visible rows are all that matter (a folder can hold thousands).
    private static let rowContainers: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser"]

    /// Clickable things in the frontmost app that are on `display` (Quartz points):
    /// open menus first (context menus and an open menu-bar menu, submenus included),
    /// then the focused window, then the menu bar's titles. Stops at `budget` seconds —
    /// some apps (web views, Electron) have huge trees — so the list may be partial.
    /// For guidance (`GuidanceController`): the frame (Quartz) of the element in the app's
    /// focused window whose `AXIdentifier`, or else its name, is `id`; nil if none within the
    /// budget.
    static func frame(ofElement id: String, pid: pid_t, budget: TimeInterval = 0.2) -> Rect? {
        guard isTrusted else { return nil }
        let app = element(appElement(pid))
        guard let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) else { return nil }
        let wanted = id.lowercased()
        let deadline = Date().addingTimeInterval(budget)
        var queue = [window][...]
        var byName: Rect?
        var visited = 0
        while let node = queue.popFirst(), visited < 2000, Date() < deadline {
            visited += 1
            if node.string("AXIdentifier")?.lowercased() == wanted, let frame = node.frame { return frame }
            if byName == nil, node.name.lowercased() == wanted, let frame = node.frame { byName = frame }
            queue.append(contentsOf: node.children(kAXChildrenAttribute))
        }
        return byName
    }

    /// For guidance: an accessibility node's frame (Quartz), as it is now.
    static func frame(of node: AXUIElement) -> Rect? {
        guard isTrusted else { return nil }
        return element(node).frame
    }

    static func visibleElements(frontmostPID pid: pid_t?, display: Rect, budget: TimeInterval = 0.4,
                                limit: Int = 150) -> [ScreenElement] {
        guard isTrusted, let pid else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        let app = element(appElement(pid))
        let menuBar = app.element(kAXMenuBarAttribute)

        var roots: [AXElement] = app.children(kAXChildrenAttribute).filter { $0.string(kAXRoleAttribute) == "AXMenu" }
        for item in menuBar?.children(kAXChildrenAttribute) ?? [] where item.bool(kAXSelectedAttribute) == true {
            roots += item.children(kAXChildrenAttribute)
        }
        // The menu bar's ~10 titles before the window: a web page can use up the whole
        // budget, and then "Safari" (the menu) wasn't found for 7 s.
        if let menuBar { roots.append(menuBar) }
        // An app that isn't in front may have no focused window: its main one then.
        if let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) { roots.append(window) }

        var found: [ScreenElement] = []
        var queue = roots[...]
        var visited = 0
        while let node = queue.popFirst(), visited < 4000, found.count < limit, Date() < deadline {
            visited += 1
            let role = node.string(kAXRoleAttribute) ?? ""
            if listedRoles.contains(role) {
                var label = role == "AXRow" ? node.rowLabel() : node.name
                // A field without a name ("where do I type?", "the message box") is still findable.
                if label.isEmpty, ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"].contains(role) { label = "text box" }
                if !label.isEmpty, let frame = node.frame, frame.width > 1, frame.height > 1,
                   frame.maxX > display.minX, frame.minX < display.maxX, frame.maxY > display.minY, frame.minY < display.maxY {
                    found.append(ScreenElement(role: role, label: label, frame: frame))
                }
                // A menu item's children are its submenu: only look inside an open one.
                // Other listed elements are leaves as far as pointing is concerned.
                guard role == "AXMenuItem", node.bool(kAXSelectedAttribute) == true else { continue }
            }
            if role == "AXMenuBarItem" { continue }  // closed menus; the open one is a root
            let key = rowContainers.contains(role) ? kAXVisibleRowsAttribute : kAXChildrenAttribute
            queue.append(contentsOf: node.children(key))
        }
        // Same thing reached twice (a menu bar title is also a root's child): keep the first.
        var seen = Set<String>()
        return found.filter { seen.insert("\($0.role)|\($0.label)|\(Int($0.frame.x))|\(Int($0.frame.y))").inserted }
    }

    /// The web page in front: its address and title, from the browser window
    /// (`AXDocument`) or its web area (`AXURL`, deep inside Safari's splits and tab
    /// groups). Safari, Chrome and other WebKit/Chromium browsers expose one of them.
    /// Nil for other apps; `trace` says what was seen (for the log).
    static func pageAddress(frontmostPID pid: pid_t?, trace: inout String) -> (address: String, title: String?)? {
        guard isTrusted, let pid else { trace = "no access"; return nil }
        requestAccessibilityTree(pid: pid)  // Chromium builds its page tree only when asked
        let app = element(appElement(pid))
        for attempt in 0..<2 {
            guard let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) else {
                trace = "no window"
                return nil
            }
            let title = window.string(kAXTitleAttribute)
            if let document = window.string(kAXDocumentAttribute), document.hasPrefix("http") {
                trace = "window document"
                return (document, title)
            }
            let deadline = Date().addingTimeInterval(0.6)
            var queue = [window][...]
            var visited = 0, webAreas = 0
            var addressBar: String?
            while let node = queue.popFirst(), visited < 3000, Date() < deadline {
                visited += 1
                let role = node.string(kAXRoleAttribute) ?? ""
                if role == "AXWebArea" {
                    webAreas += 1
                    let value = node.attribute(kAXURLAttribute)
                    if let address = (value as? URL)?.absoluteString ?? (value as? String), address.hasPrefix("http") {
                        trace = "web area after \(visited) elements"
                        return (address, title)
                    }
                    continue  // don't walk the page itself
                }
                // Chrome's address bar ("Address and search bar"), in the toolbar.
                if role == "AXTextField", addressBar == nil,
                   let value = node.string(kAXValueAttribute), let address = PageAddress.fromAddressBar(value) {
                    addressBar = address
                }
                if ["AXButton", "AXStaticText", "AXImage", "AXMenuBar"].contains(role) { continue }
                queue.append(contentsOf: node.children(kAXChildrenAttribute))
            }
            if let addressBar {
                trace = "address bar after \(visited) elements"
                return (addressBar, title)
            }
            trace = "\(visited) elements, \(webAreas) web area(s) without an address\(attempt == 1 ? " (after waiting)" : "")"
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.4) }  // the tree may still be building
        }
        return nil
    }

    /// The browser's address bar (Quartz frame): the widest text field in the top part of
    /// the front window, outside the page. Found by shape, not name — Safari and Chrome
    /// name it differently, and the name a model guesses rarely matches.
    static func addressBarFrame(frontmostPID pid: pid_t?) -> Rect? {
        guard isTrusted, let pid else { return nil }
        let app = element(appElement(pid))
        guard let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute),
              let windowFrame = window.frame else { return nil }
        let deadline = Date().addingTimeInterval(0.4)
        var queue = [window][...]
        var visited = 0
        var best: Rect?
        while let node = queue.popFirst(), visited < 2000, Date() < deadline {
            visited += 1
            let role = node.string(kAXRoleAttribute) ?? ""
            if role == "AXWebArea" { continue }
            if ["AXTextField", "AXSearchField", "AXComboBox"].contains(role), let frame = node.frame,
               frame.y < windowFrame.y + 140, frame.width > 200, frame.width > (best?.width ?? 0) {
                best = frame
                continue
            }
            if ["AXButton", "AXStaticText", "AXImage"].contains(role) { continue }
            queue.append(contentsOf: node.children(kAXChildrenAttribute))
        }
        return best
    }

    /// A browser tab already showing `site` ("YouTube"), selected and its window brought to
    /// the front: "go to YouTube" switches to it rather than opening another. Matches tab
    /// titles (Chrome's tabs are AX radio buttons, Safari's are tabs). False if none.
    static func selectTab(showing site: String, browserPID pid: pid_t) -> Bool {
        let wanted = site.lowercased()
        return selectTab(browserPID: pid) { $0.lowercased().contains(wanted) }
    }

    /// Presses the first tab (front window first) whose name `matches`, and raises its window.
    static func selectTab(browserPID pid: pid_t, where matches: (String) -> Bool) -> Bool {
        guard isTrusted else { return false }
        let app = element(appElement(pid))
        let deadline = Date().addingTimeInterval(0.5)
        for window in app.children(kAXWindowsAttribute) {
            var queue = [window][...]
            var visited = 0
            while let node = queue.popFirst(), visited < 1500, Date() < deadline {
                visited += 1
                let role = node.string(kAXRoleAttribute) ?? ""
                if role == "AXWebArea" { continue }
                if role == "AXRadioButton" || role == "AXTab" || node.string(kAXSubroleAttribute) == "AXTabButton",
                   matches(node.name) {
                    node.perform(kAXPressAction)
                    AXUIElementSetAttributeValue(window.ref, kAXMainAttribute as CFString, kCFBooleanTrue)
                    window.perform(kAXRaiseAction)
                    return true
                }
                queue.append(contentsOf: node.children(kAXChildrenAttribute))
            }
        }
        return false
    }

    /// "go there!": the app's window a background job came from (`HomeWindow.best`), brought
    /// back from the Dock if minimised and raised to the front of its app. False when no
    /// window matches (the caller still activates the app).
    enum HomeReturn: String { case byTitle = "its window, by title", byTab = "its tab, selected", byFrame = "a window by frame only", none = "app only, its window wasn't found" }

    /// The app's real window under `point` (Quartz): its accessibility windows are front to
    /// back and only real ones — the window list also has a browser's invisible helper
    /// windows (Chrome: full-screen and strip-shaped ones on top), which a snip's middle can
    /// land on. Its title is the page shown (a browser's active tab).
    static func window(at point: Point, pid: pid_t) -> (title: String?, frame: Rect)? {
        guard isTrusted else { return nil }
        for window in element(appElement(pid)).children(kAXWindowsAttribute) {
            guard window.bool(kAXMinimizedAttribute) != true, let frame = window.frame,
                  point.x >= frame.minX, point.x <= frame.maxX, point.y >= frame.minY, point.y <= frame.maxY else { continue }
            return (window.string(kAXTitleAttribute), frame)
        }
        return nil
    }

    @discardableResult
    static func raiseHomeWindow(pid: pid_t, title: String?, frame: Rect?) -> HomeReturn {
        guard isTrusted, title != nil || frame != nil else { return .none }
        let windows = element(appElement(pid)).children(kAXWindowsAttribute)
        let described = windows.map { (title: $0.string(kAXTitleAttribute), frame: $0.frame) }
        let index = HomeWindow.best(described, title: title, frame: frame)
        // No window shows it now: it's a tab that's no longer in front (or windows stacked
        // on one frame). Find the tab by its page title, select it and raise its window.
        let byTitle = index.map { HomeWindow.titlesMatch(described[$0].title, title) } ?? false
        if !byTitle, let title, selectTab(browserPID: pid, where: { HomeWindow.tabMatches($0, page: title) }) {
            return .byTab
        }
        guard let index else { return .none }
        let window = windows[index]
        if window.bool(kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(window.ref, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window.ref, kAXMainAttribute as CFString, kCFBooleanTrue)
        window.perform(kAXRaiseAction)
        return byTitle ? .byTitle : .byFrame
    }

    /// Where typing would go in `pid`: the text caret of its focused element (Quartz), from
    /// `AXSelectedTextRange` and `AXBoundsForRange` — exact and instant, no model. Nil when
    /// nothing focused takes text or the app doesn't report the caret's place.
    static func caretRect(pid: pid_t) -> Rect? {
        guard isTrusted, let focused = element(appElement(pid)).element(kAXFocusedUIElementAttribute),
              let selection = focused.attribute(kAXSelectedTextRangeAttribute), CFGetTypeID(selection) == AXValueGetTypeID()
        else { return nil }
        var cfRange = CFRange()
        // Type ID checked above.
        guard AXValueGetValue(unsafeDowncast(selection, to: AXValue.self), .cfRange, &cfRange) else { return nil }
        // An empty selection has no height (measured in Terminal): measure the character at
        // the caret instead (the one before it at the very end).
        if cfRange.length == 0 {
            let count = (focused.attribute(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue ?? 0
            cfRange = CFRange(location: cfRange.location >= count && cfRange.location > 0 ? cfRange.location - 1 : cfRange.location, length: 1)
        }
        guard let range = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var bounds: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(focused.ref, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         range, &bounds) == .success,
              let value = bounds, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        // Type ID checked above.
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &rect), rect.height > 0 else { return nil }
        return Rect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: rect.height)
    }

    /// The app's focused window on the current desktop (Quartz), for placing the chat.
    static func focusedWindowFrameOnScreen(pid: pid_t) -> Rect? {
        guard isTrusted else { return nil }
        return element(appElement(pid)).element(kAXFocusedWindowAttribute)?.frame
    }

    #if DEBUG
    /// For the "go there!" check (`CLICKBAIT_TEST_GOTHERE`): the focused window on the current desktop.
    static func focusedWindowTitle(pid: pid_t) -> String? {
        element(appElement(pid)).element(kAXFocusedWindowAttribute)?.string(kAXTitleAttribute)
    }

    #endif

    /// Brings the app to the front through accessibility. `NSRunningApplication.activate()`
    /// asked by a background app (ClickBait never becomes active) can be quietly refused;
    /// this isn't, and it switches to the app's Space.
    static func bringToFront(pid: pid_t) {
        guard isTrusted else { return }
        AXUIElementSetAttributeValue(element(appElement(pid)).ref,
                                     kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// The app whose window is under `point` (Quartz) — the one the user is looking at
    /// when the frontmost app's windows are on another display. From the window list
    /// (front to back, normal windows only), so ClickBait's own see-through overlays,
    /// which cover whole screens, never count.
    static func appPID(at point: Point) -> pid_t? {
        window(at: point)?.pid
    }

    /// The app whose real window is in front under `point` (Quartz): the window list front to
    /// back, each app checked against its accessibility windows, so a browser's invisible
    /// helper windows (Chrome keeps full-screen ones on top) don't count.
    static func appWithWindow(at point: Point) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let own = getpid()
        var checked = Set<pid_t>()
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != own, !checked.contains(pid),
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  point.x >= x, point.x <= x + width, point.y >= y, point.y <= y + height
            else { continue }
            checked.insert(pid)
            if self.window(at: point, pid: pid) != nil { return pid }
        }
        return nil
    }

    /// The front normal window under `point` (Quartz): its app, title (needs Screen
    /// Recording, else nil) and frame (Quartz, top-left origin, as accessibility frames are).
    static func window(at point: Point) -> (pid: pid_t, title: String?, frame: Rect)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let own = getpid()
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  point.x >= x, point.x <= x + width, point.y >= y, point.y <= y + height
            else { continue }
            let title = (window[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (pid, title, Rect(x: x, y: y, width: width, height: height))
        }
        return nil
    }

    // MARK: - Menus (tutorials)

    /// Submenus of recently used apps, documents and servers (never searched for steps).
    private static let recentItemsMenus: Set = ["recent items", "open recent", "recent documents", "recent places"]

    /// Where a menu item lives in the frontmost app's menus, even while they're closed:
    /// ["View", "Show Path Bar"], or ["Format", "Font", "Bold"] for a submenu. Lets a
    /// tutorial point at the menu to open when the model skipped that step.
    static func menuPath(to label: String, frontmostPID pid: pid_t?, budget: TimeInterval = 0.4) -> [String]? {
        guard isTrusted, let pid, let bar = element(appElement(pid)).element(kAXMenuBarAttribute) else { return nil }
        let deadline = Date().addingTimeInterval(budget)
        var best: (path: [String], score: Double)?

        func search(_ menu: AXElement, path: [String], depth: Int) {
            guard depth < 3 else { return }
            for item in menu.children(kAXChildrenAttribute) {
                guard Date() < deadline else { return }
                let title = item.name
                guard !title.isEmpty else { continue }
                // Deeper matches count a little less: the real "System Settings…" in the
                // Apple menu beats a near-identical entry a submenu down.
                let score = LabelMatcher.similarity(label, title) - 0.05 * Double(depth)
                if score >= 0.8, score > (best?.score ?? 0) { best = (path + [title], score) }
                // Recent apps and files aren't commands: Apple ▸ Recent Items lists "System
                // Settings" too, and the walkthrough sent people into Recent Items for it.
                guard !Self.recentItemsMenus.contains(title.lowercased()) else { continue }
                if let submenu = item.children(kAXChildrenAttribute).first(where: { $0.string(kAXRoleAttribute) == "AXMenu" }) {
                    search(submenu, path: path + [title], depth: depth + 1)
                }
            }
        }
        // The Apple menu too: without it, "System Settings…" matched Finder ▸ Settings… (a
        // loose 0.8) and the walkthrough pointed at the Finder menu instead.
        for top in bar.children(kAXChildrenAttribute) {
            let title = top.name
            guard !title.isEmpty, let menu = top.children(kAXChildrenAttribute).first else { continue }
            search(menu, path: [title], depth: 0)
            if best?.score == 1 { break }
        }
        return best?.path
    }

    /// The item at `path` (["History", "Clear History…"]) while its menu is open, read
    /// straight from the menu bar: the open-menu scan in `visibleElements` can miss a
    /// menu-bar menu mid-tracking. Nil when the item has no frame on screen.
    static func openMenuItemFrame(_ path: [String], frontmostPID pid: pid_t?) -> Rect? {
        guard isTrusted, let pid, path.count >= 2,
              let bar = element(appElement(pid)).element(kAXMenuBarAttribute) else { return nil }
        var item = bar.children(kAXChildrenAttribute).first { $0.name == path[0] }
        for title in path.dropFirst() {
            guard let menu = item?.children(kAXChildrenAttribute).first(where: { $0.string(kAXRoleAttribute) == "AXMenu" }) else { return nil }
            item = menu.children(kAXChildrenAttribute).first { $0.name == title }
        }
        guard let frame = item?.frame, frame.width > 1, frame.height > 1, frame.y > 1 else { return nil }
        return frame
    }

    /// The frontmost app's menus as "History ▸ Clear History…" lines (two levels, no
    /// Apple menu), for planning tutorials with the app's real item names.
    static func menuOutline(frontmostPID pid: pid_t?, limit: Int = 160, budget: TimeInterval = 0.5) -> [String] {
        guard isTrusted, let pid, let bar = element(appElement(pid)).element(kAXMenuBarAttribute) else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        var lines: [String] = []
        for top in bar.children(kAXChildrenAttribute) {
            let title = top.name
            guard !title.isEmpty, title != "Apple", let menu = top.children(kAXChildrenAttribute).first else { continue }
            for item in menu.children(kAXChildrenAttribute) {
                guard Date() < deadline, lines.count < limit else { return lines }
                let name = item.name
                guard !name.isEmpty else { continue }
                if let submenu = item.children(kAXChildrenAttribute).first(where: { $0.string(kAXRoleAttribute) == "AXMenu" }) {
                    for sub in submenu.children(kAXChildrenAttribute).prefix(12) {
                        let subName = sub.name
                        if !subName.isEmpty, lines.count < limit { lines.append("\(title) ▸ \(name) ▸ \(subName)") }
                    }
                } else {
                    lines.append("\(title) ▸ \(name)")
                }
            }
        }
        return lines
    }

    /// The words the app shows inside `region` (Quartz points): text, headings, links, buttons,
    /// in its windows, capped; for a snip, exact even when the close-up is soft.
    static func texts(in region: Rect, pid: pid_t?, budget: TimeInterval = 0.3) -> String {
        guard isTrusted, let pid else { return "" }
        let deadline = Date().addingTimeInterval(budget)
        var parts: [String] = []
        var stack = element(appElement(pid)).children(kAXWindowsAttribute)
        while let item = stack.popLast(), Date() < deadline, parts.joined().count < 800 {
            guard let frame = item.frame, frame.maxX >= region.minX, frame.minX <= region.maxX,
                  frame.maxY >= region.minY, frame.minY <= region.maxY else { continue }
            let role = item.string(kAXRoleAttribute) ?? ""
            if role == "AXSecureTextField" { continue }
            if ["AXStaticText", "AXHeading", "AXLink", "AXButton", "AXTextArea", "AXTextField", "AXCell"].contains(role) {
                let text = (item.attribute(kAXValueAttribute) as? String) ?? item.name
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !parts.contains(text) { parts.append(text) }
            }
            stack.append(contentsOf: item.children(kAXChildrenAttribute).reversed())
        }
        return parts.joined(separator: " · ")
    }

    /// Where a menu's title is in the app's menu bar ("History"), named exactly (case aside).
    static func menuBarItemFrame(_ title: String, pid: pid_t?) -> Rect? {
        guard isTrusted, let pid, let bar = element(appElement(pid)).element(kAXMenuBarAttribute) else { return nil }
        let wanted = title.lowercased()
        return bar.children(kAXChildrenAttribute).first { $0.name.lowercased() == wanted }?.frame
    }

    /// The menu bar's right side: Control Center, Wi‑Fi, Battery, the clock and the other
    /// system status items (Control Center's and SystemUIServer's), left to right.
    static func menuExtras() -> [ScreenElement] {
        guard isTrusted else { return [] }
        let owners = ["com.apple.controlcenter", "com.apple.systemuiserver"]
        let items = owners.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.flatMap { app in
            element(appElement(app.processIdentifier)).element(kAXExtrasMenuBarAttribute)?
                .children(kAXChildrenAttribute).compactMap { item in
                    item.frame.map { ScreenElement(role: "AXMenuBarItem", label: item.name, frame: $0) }
                } ?? []
        }
        return items.sorted { $0.frame.x < $1.frame.x }
    }

    // MARK: - Finder items

    /// The files under `points` (Quartz) in Finder: list, column and icon view and the
    /// desktop expose each item's file URL (`AXURL`) on the item or a parent of it.
    /// Displayed names aren't used — extensions can be hidden and headers look like names.
    static func finderItemURLs(at points: [Point], finderPID pid: pid_t) -> [URL] {
        guard isTrusted else { return [] }
        let app = element(appElement(pid))
        var urls: [URL] = []
        var seen = Set<String>()
        for point in points {
            guard let hit = app.hitTest(point) else { continue }
            var current: AXElement? = hit
            for _ in 0..<5 {
                guard let element = current else { break }
                if let url = element.fileURL {
                    if seen.insert(url.standardizedFileURL.path).inserted { urls.append(url) }
                    break
                }
                let role = element.string(kAXRoleAttribute) ?? ""
                if role == "AXWindow" || role == "AXScrollArea" || role == "AXOutline" || role == "AXBrowser" { break }
                current = element.element(kAXParentAttribute)
            }
        }
        return urls
    }

    // MARK: - Snapping

    /// Actionable elements around `point` (Quartz global points), found by hit-testing
    /// a small grid of rings out to the snapping radius.
    /// What the hit-tests saw, for diagnosing snapping. Roles only — never names or text.
    struct Probe: CustomStringConvertible {
        var samples = 0
        var hits = 0
        var ownHits = 0
        var roles: [String: Int] = [:]

        /// Accessibility actually exposes what's drawn here. Web pages without
        /// accessibility, Electron apps and games show up only as containers, so finding
        /// nothing clickable there says nothing about what's on screen.
        var seesContent: Bool {
            let containers: Set<String> = ["AXScrollArea", "AXGroup", "AXWindow", "AXSplitGroup", "AXLayoutArea",
                                           "AXWebArea", "AXUnknown", "AXApplication", "AXSplitter"]
            return roles.keys.contains { !containers.contains($0) }
        }

        var description: String {
            let top = roles.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            return "\(hits)/\(samples) hits, \(ownHits) on ClickBait's own windows, roles: \(top.isEmpty ? "none" : top)"
        }
    }

    static func candidates(around point: Point, frontmostPID: pid_t?) -> ([SnapCandidate], Probe) {
        var probe = Probe()
        guard isTrusted else { return ([], probe) }
        let systemWide = element(AXUIElementCreateSystemWide())
        let frontmostApp = frontmostPID.map { element(appElement($0)) }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var samples = [point]
        for radius in [10.0, 22.0, 34.0] {
            for step in 0..<8 {
                let angle = Double(step) * .pi / 4
                samples.append(Point(x: point.x + radius * cos(angle), y: point.y + radius * sin(angle)))
            }
        }

        var seen: [AXUIElement] = []
        var found: [SnapCandidate] = []
        probe.samples = samples.count
        for sample in samples {
            var hit = systemWide.hitTest(sample)
            // ClickBait's own panels can be on top; look straight into the frontmost app.
            if hit?.pid == ownPID {
                probe.ownHits += 1
                hit = frontmostApp?.hitTest(sample)
            }
            if let hit {
                probe.hits += 1
                probe.roles[hit.string(kAXRoleAttribute) ?? "?", default: 0] += 1
            }
            guard let actionable = hit?.actionableAncestor(),
                  !seen.contains(where: { CFEqual($0, actionable.ref) })
            else { continue }
            seen.append(actionable.ref)
            if let frame = actionable.frame, frame.width > 0, frame.height > 0 {
                found.append(SnapCandidate(role: actionable.string(kAXRoleAttribute) ?? "", label: actionable.name, frame: frame))
            }
        }
        return (found, probe)
    }

    private static func element(_ ref: AXUIElement) -> AXElement {
        AXUIElementSetMessagingTimeout(ref, timeout)
        return AXElement(ref: ref)
    }
}

/// Thin wrapper around `AXUIElement` attribute reads.
private struct AXElement {
    let ref: AXUIElement

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(ref, &pid) == .success ? pid : nil
    }

    func attribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success ? value : nil
    }

    func string(_ name: String) -> String? {
        (attribute(name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(ref, action as CFString) == .success
    }

    func element(_ name: String) -> AXElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // CF types can't be cast with `as?`; the type ID check above makes this safe.
        return AXElement(ref: unsafeDowncast(value, to: AXUIElement.self))
    }

    /// The name a person would read: title, else description, else help or placeholder.
    var name: String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute] {
            if let value = string(key), !value.isEmpty { return value }
        }
        if let titleElement = element(kAXTitleUIElementAttribute), let value = titleElement.string(kAXValueAttribute) {
            return value
        }
        return ""
    }

    /// Frame in Quartz global points.
    var frame: Rect? {
        guard let positionValue = attribute(kAXPositionAttribute), let sizeValue = attribute(kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        // Type IDs checked above.
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return Rect(x: position.x, y: position.y, width: size.width, height: size.height)
    }

    /// Web content exposes its selection as a text-marker range, readable through the
    /// parameterized `AXStringForTextMarkerRange` attribute.
    func selectedTextViaMarkers() -> String? {
        guard let range = attribute("AXSelectedTextMarkerRange") else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(ref, "AXStringForTextMarkerRange" as CFString, range, &value) == .success
        else { return nil }
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `AXURL` when it's a file on disk (Finder items).
    var fileURL: URL? {
        guard let value = attribute(kAXURLAttribute), CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        let url = unsafeDowncast(value, to: CFURL.self) as URL
        return url.isFileURL ? url : nil
    }

    func children(_ name: String) -> [AXElement] {
        guard let value = attribute(name), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AXUIElement] ?? []).map(AXElement.init(ref:))
    }

    func bool(_ name: String) -> Bool? {
        attribute(name) as? Bool
    }

    /// A table or sidebar row's name: the first text inside it.
    func rowLabel() -> String {
        var queue = children(kAXChildrenAttribute)[...]
        var steps = 0
        while let node = queue.popFirst(), steps < 12 {
            steps += 1
            if node.string(kAXRoleAttribute) == "AXStaticText", let text = node.string(kAXValueAttribute), !text.isEmpty {
                return text
            }
            let title = node.name
            if !title.isEmpty, node.string(kAXRoleAttribute) != "AXImage" { return title }
            queue.append(contentsOf: node.children(kAXChildrenAttribute))
        }
        return ""
    }

    func hitTest(_ point: Point) -> AXElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(ref, Float(point.x), Float(point.y), &hit) == .success, let hit else {
            return nil
        }
        return AXElement(ref: hit)
    }

    /// This element or the nearest ancestor (up to 4 levels) that can be clicked or typed in.
    func actionableAncestor() -> AXElement? {
        var current: AXElement? = self
        for _ in 0..<5 {
            guard let element = current else { return nil }
            if let role = element.string(kAXRoleAttribute), Snapper.actionableRoles.contains(role) { return element }
            current = element.element(kAXParentAttribute)
        }
        return nil
    }
}

// MARK: - Dictation

/// Where fn+⌃ dictation's words will go, and the words on screen that help spell them.
struct DictationTarget: Sendable {
    var windowTitle: String?
    /// Names of controls in the app's window (buttons, labels, links…).
    var labels: [String] = []
    var role: String?
    var subrole: String?
    /// The focused element takes typed text.
    var editable = false
    /// Its text up to the caret (the last few hundred characters).
    var textBeforeCaret: String?
    /// The text selected in it, if any (fn+⌃ writing reworks it).
    var selectedText: String?
    /// All its text (capped), for "make it shorter" on a draft.
    var fieldText: String?
    /// The window's visible text (capped), for "reply to this email".
    var windowText: String?
}

extension AXInspector {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Read at the press of fn+⌃, off the main thread. Password fields give their role only,
    /// never their text.
    static func dictationTarget(pid: pid_t?) -> DictationTarget {
        guard isTrusted, let pid else { return DictationTarget() }
        var target = DictationTarget()
        let app = element(appElement(pid))
        let window = app.element(kAXFocusedWindowAttribute)
        target.windowTitle = window?.string(kAXTitleAttribute)
        if let focused = element(AXUIElementCreateSystemWide()).element(kAXFocusedUIElementAttribute)
            ?? app.element(kAXFocusedUIElementAttribute) {
            target.role = focused.string(kAXRoleAttribute)
            target.subrole = focused.string(kAXSubroleAttribute)
            var settable = DarwinBoolean(false)
            let valueSettable = AXUIElementIsAttributeSettable(focused.ref, kAXValueAttribute as CFString, &settable) == .success
                && settable.boolValue
            target.editable = valueSettable || target.role.map(textRoles.contains) == true
            if target.editable, target.subrole != "AXSecureTextField", let value = focused.attribute(kAXValueAttribute) as? String {
                var caret = value.utf16.count
                if let selection = focused.attribute(kAXSelectedTextRangeAttribute), CFGetTypeID(selection) == AXValueGetTypeID() {
                    var range = CFRange()
                    // Type ID checked above.
                    if AXValueGetValue(unsafeDowncast(selection, to: AXValue.self), .cfRange, &range) { caret = range.location }
                }
                let before = String(value.utf16.prefix(max(0, min(caret, value.utf16.count)))) ?? ""
                target.textBeforeCaret = String(before.suffix(300))
                target.fieldText = String(value.prefix(DictationWriting.maxSubject))
                if let selected = focused.attribute(kAXSelectedTextAttribute) as? String,
                   !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    target.selectedText = String(selected.prefix(DictationWriting.maxSubject))
                }
            }
        }
        if let frame = window?.frame {
            target.labels = visibleElements(frontmostPID: pid, display: frame, budget: 0.25, limit: 80).map(\.label)
        }
        if let window { target.windowText = windowText(window) }
        return target
    }

    /// The window's words, in reading order as far as Accessibility gives them (static text and
    /// text areas), capped; a short time budget so the press never waits on a huge page.
    private static func windowText(_ window: AXElement, budget: TimeInterval = 0.35) -> String {
        let deadline = Date().addingTimeInterval(budget)
        var parts: [String] = []
        var total = 0
        var stack = [window]
        while let element = stack.popLast(), Date() < deadline, total < DictationWriting.maxScreen {
            let role = element.string(kAXRoleAttribute) ?? ""
            if role == "AXSecureTextField" { continue }
            if ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink"].contains(role),
               let value = (element.attribute(kAXValueAttribute) as? String) ?? element.string(kAXTitleAttribute),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(value)
                total += value.count
            }
            stack.append(contentsOf: element.children(kAXChildrenAttribute).reversed())
        }
        return String(parts.joined(separator: "\n").prefix(DictationWriting.maxScreen))
    }

    /// Selects `text` in the focused field (its last occurrence; the whole field when nil), so
    /// what's pasted next replaces it. False when the field won't say or won't take a selection.
    static func selectInFocusedField(_ text: String?, pid: pid_t?) -> Bool {
        guard isTrusted, let pid else { return false }
        let app = element(appElement(pid))
        guard let focused = element(AXUIElementCreateSystemWide()).element(kAXFocusedUIElementAttribute)
                ?? app.element(kAXFocusedUIElementAttribute),
              let value = focused.attribute(kAXValueAttribute) as? String else { return false }
        let whole = value as NSString
        let range = text.map { whole.range(of: $0, options: .backwards) } ?? NSRange(location: 0, length: whole.length)
        guard range.location != NSNotFound, range.length > 0 else { return false }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(focused.ref, kAXSelectedTextRangeAttribute as CFString, axRange) == .success
    }
}
