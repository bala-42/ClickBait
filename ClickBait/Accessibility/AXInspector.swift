import AppKit
import ApplicationServices
import os
import ClickBaitCore

/// What the accessibility API says about the frontmost app when the hotkey is pressed.
struct AXSnapshot: Sendable {
    var windowTitle: String?
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
    private static let timeout: Float = 0.15

    static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - Context

    static func snapshot(frontmostPID: pid_t?) -> AXSnapshot {
        guard isTrusted else { return AXSnapshot() }
        var result = AXSnapshot()

        if let pid = frontmostPID {
            let app = element(AXUIElementCreateApplication(pid))
            if let window = app.element(kAXFocusedWindowAttribute) {
                result.windowTitle = window.string(kAXTitleAttribute)
            }
        }

        let systemWide = element(AXUIElementCreateSystemWide())
        // Some apps only answer "what's focused" when asked directly.
        let focused = systemWide.element(kAXFocusedUIElementAttribute)
            ?? frontmostPID.flatMap { element(AXUIElementCreateApplication($0)).element(kAXFocusedUIElementAttribute) }
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
        let app = AXUIElementCreateApplication(pid)
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
    static func visibleElements(frontmostPID pid: pid_t?, display: Rect, budget: TimeInterval = 0.4,
                                limit: Int = 150) -> [ScreenElement] {
        guard isTrusted, let pid else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        let app = element(AXUIElementCreateApplication(pid))
        let menuBar = app.element(kAXMenuBarAttribute)

        var roots: [AXElement] = app.children(kAXChildrenAttribute).filter { $0.string(kAXRoleAttribute) == "AXMenu" }
        for item in menuBar?.children(kAXChildrenAttribute) ?? [] where item.bool(kAXSelectedAttribute) == true {
            roots += item.children(kAXChildrenAttribute)
        }
        if let window = app.element(kAXFocusedWindowAttribute) { roots.append(window) }
        if let menuBar { roots.append(menuBar) }

        var found: [ScreenElement] = []
        var queue = roots[...]
        var visited = 0
        while let node = queue.popFirst(), visited < 4000, found.count < limit, Date() < deadline {
            visited += 1
            let role = node.string(kAXRoleAttribute) ?? ""
            if listedRoles.contains(role) {
                let label = role == "AXRow" ? node.rowLabel() : node.name
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
        let app = element(AXUIElementCreateApplication(pid))
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
        while let node = queue.popFirst(), visited < 3000, Date() < deadline {
            visited += 1
            let role = node.string(kAXRoleAttribute) ?? ""
            if role == "AXWebArea" {
                webAreas += 1
                let value = node.attribute(kAXURLAttribute)
                let address = (value as? URL)?.absoluteString ?? (value as? String)
                if let address, address.hasPrefix("http") {
                    trace = "web area after \(visited) elements"
                    return (address, title)
                }
                continue  // don't walk the page itself
            }
            if ["AXToolbar", "AXMenuBar", "AXButton", "AXStaticText", "AXImage"].contains(role) { continue }
            queue.append(contentsOf: node.children(kAXChildrenAttribute))
        }
        trace = "\(visited) elements, \(webAreas) web area(s) without an address"
        return nil
    }

    // MARK: - Menus (tutorials)

    /// Where a menu item lives in the frontmost app's menus, even while they're closed:
    /// ["View", "Show Path Bar"], or ["Format", "Font", "Bold"] for a submenu. Lets a
    /// tutorial point at the menu to open when the model skipped that step.
    static func menuPath(to label: String, frontmostPID pid: pid_t?, budget: TimeInterval = 0.4) -> [String]? {
        guard isTrusted, let pid, let bar = element(AXUIElementCreateApplication(pid)).element(kAXMenuBarAttribute) else { return nil }
        let deadline = Date().addingTimeInterval(budget)
        var best: (path: [String], score: Double)?

        func search(_ menu: AXElement, path: [String], depth: Int) {
            guard depth < 3 else { return }
            for item in menu.children(kAXChildrenAttribute) {
                guard Date() < deadline else { return }
                let title = item.name
                guard !title.isEmpty else { continue }
                let score = LabelMatcher.similarity(label, title)
                if score >= 0.8, score > (best?.score ?? 0) { best = (path + [title], score) }
                if let submenu = item.children(kAXChildrenAttribute).first(where: { $0.string(kAXRoleAttribute) == "AXMenu" }) {
                    search(submenu, path: path + [title], depth: depth + 1)
                }
            }
        }
        for top in bar.children(kAXChildrenAttribute) {
            let title = top.name
            guard !title.isEmpty, title != "Apple", let menu = top.children(kAXChildrenAttribute).first else { continue }
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
              let bar = element(AXUIElementCreateApplication(pid)).element(kAXMenuBarAttribute) else { return nil }
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
        guard isTrusted, let pid, let bar = element(AXUIElementCreateApplication(pid)).element(kAXMenuBarAttribute) else { return [] }
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

    // MARK: - Finder items

    /// The files under `points` (Quartz) in Finder: list, column and icon view and the
    /// desktop expose each item's file URL (`AXURL`) on the item or a parent of it.
    /// Displayed names aren't used — extensions can be hidden and headers look like names.
    static func finderItemURLs(at points: [Point], finderPID pid: pid_t) -> [URL] {
        guard isTrusted else { return [] }
        let app = element(AXUIElementCreateApplication(pid))
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
        let frontmostApp = frontmostPID.map { element(AXUIElementCreateApplication($0)) }
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
