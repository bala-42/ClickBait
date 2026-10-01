import AppKit
import ApplicationServices
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

    // MARK: - Snapping

    /// Actionable elements around `point` (Quartz global points), found by hit-testing
    /// a small grid of rings out to the snapping radius.
    /// What the hit-tests saw, for diagnosing snapping. Roles only — never names or text.
    struct Probe: CustomStringConvertible {
        var samples = 0
        var hits = 0
        var ownHits = 0
        var roles: [String: Int] = [:]

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
