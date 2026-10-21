import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

/// Follows the System Settings window so the permission guide (`PermissionGuide`) can fly to
/// it and stay attached while the user flips a switch or drags ClickBait into a list. Two
/// sources: a 30 Hz window-server poll (needs no permission; the start and the fallback) and
/// Accessibility move/resize observers once ClickBait is trusted. Twelve misses in a row
/// mean System Settings closed, and `onTrackingEnded` fires.
///
/// Adapted from Sentient OS (AGPL-3.0), itself adapted from PermissionFlow by 小弟调调
/// (MIT); see THIRD_PARTY_NOTICES.md. The window-server heuristics and the CG → AppKit
/// flip are hard-won upstream; check there before simplifying.
@MainActor
final class SettingsWindowTracker {
    /// The poll stays on with Accessibility too: Settings can appear before observers attach.
    private let pollInterval: TimeInterval = 1.0 / 30.0
    /// Lookups miss while Settings opens or swaps panes; several in a row mean it closed.
    private let missingAppThreshold = 12

    var onFrameChange: ((CGRect) -> Void)?
    var onTrackingEnded: (() -> Void)?
    private(set) var currentFrame: CGRect?

    private let bundleIdentifier = "com.apple.systempreferences"
    private var appObserver: AXObserver?
    private var windowObserver: AXObserver?
    private var observedWindow: AXUIElement?
    private var pollTimer: Timer?
    private var hasActiveTrackingTarget = false
    private var missingAppPollCount = 0

    func startTracking() {
        stopTracking()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachIfNeeded() }
        }
        pollTimer?.tolerance = pollInterval * 0.25
        attachIfNeeded()
    }

    func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer = appObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        if let observer = windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        appObserver = nil
        windowObserver = nil
        observedWindow = nil
        currentFrame = nil
        hasActiveTrackingTarget = false
        missingAppPollCount = 0
    }

    /// Finds the running System Settings, reports its window-server frame at once, and
    /// attaches Accessibility observers when allowed.
    private func attachIfNeeded() {
        guard let app = runningSettingsApplication() else {
            finishTrackingIfNeededBecauseAppExited()
            return
        }
        hasActiveTrackingTarget = true
        missingAppPollCount = 0

        updateFrameFromWindowServer(for: app.processIdentifier)
        guard AXIsProcessTrusted() else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if appObserver == nil {
            appObserver = makeObserver(for: app.processIdentifier)
            if let appObserver {
                addNotification(kAXMainWindowChangedNotification as CFString, element: appElement, observer: appObserver)
                addNotification(kAXFocusedWindowChangedNotification as CFString, element: appElement, observer: appObserver)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(appObserver), .commonModes)
            }
        }

        guard let window = mainWindow(for: appElement) else { return }
        guard !isSameElement(window, observedWindow) else {
            updateCurrentFrame()
            return
        }
        observedWindow = window
        updateWindowObserver(for: app.processIdentifier, window: window)
        updateCurrentFrame()
    }

    private func updateFrameFromWindowServer(for pid: pid_t) {
        guard let frame = windowServerFrame(for: pid), currentFrame != frame else { return }
        currentFrame = frame
        onFrameChange?(frame)
    }

    private func updateWindowObserver(for pid: pid_t, window: AXUIElement) {
        if let windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .commonModes)
        }
        windowObserver = makeObserver(for: pid)
        if let windowObserver {
            addNotification(kAXMovedNotification as CFString, element: window, observer: windowObserver)
            addNotification(kAXResizedNotification as CFString, element: window, observer: windowObserver)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .commonModes)
        }
    }

    private func updateCurrentFrame() {
        guard let window = observedWindow,
              let position = pointValue(for: kAXPositionAttribute, element: window),
              let size = sizeValue(for: kAXSizeAttribute, element: window) else { return }
        let frame = appKitFrame(fromGlobalTopLeftFrame: CGRect(origin: position, size: size))
        guard currentFrame != frame else { return }
        currentFrame = frame
        onFrameChange?(frame)
    }

    /// The main window, else the focused one, else the first listed.
    private func mainWindow(for appElement: AXUIElement) -> AXUIElement? {
        if let window = elementValue(for: kAXMainWindowAttribute, element: appElement) { return window }
        if let window = elementValue(for: kAXFocusedWindowAttribute, element: appElement) { return window }
        return arrayValue(for: kAXWindowsAttribute, element: appElement)?.first
    }

    /// Every notification goes back through `attachIfNeeded` on the main actor.
    private func makeObserver(for pid: pid_t) -> AXObserver? {
        var observer: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<SettingsWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in tracker.attachIfNeeded() }
        }, &observer)
        return result == .success ? observer : nil
    }

    private func addNotification(_ name: CFString, element: AXUIElement, observer: AXObserver) {
        _ = AXObserverAddNotification(observer, element, name, Unmanaged.passUnretained(self).toOpaque())
    }

    private func elementValue(for key: String, element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func arrayValue(for key: String, element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func pointValue(for key: String, element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeValue(for key: String, element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func isSameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    /// A System Settings process with a UI before a background helper.
    private func runningSettingsApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .max(by: { ($0.activationPolicy == .prohibited ? 0 : 1) < ($1.activationPolicy == .prohibited ? 0 : 1) })
    }

    /// The largest visible layer-0 window of the System Settings process. Its bounds can read
    /// taller than the content edge, so the panel's attachment is tuned in
    /// `PermissionGuidePanel.targetFrame`, not here.
    private func windowServerFrame(for pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return windows
            .filter { window in
                guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else { return false }
                let layer = window[kCGWindowLayer as String] as? Int ?? 0
                let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
                return layer == 0 && alpha > 0
            }
            .compactMap { window -> CGRect? in
                guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                      let cgBounds = CGRect(dictionaryRepresentation: bounds) else { return nil }
                let frame = appKitFrame(fromGlobalTopLeftFrame: cgBounds)
                guard frame.width > 320, frame.height > 240 else { return nil }
                return frame
            }
            .max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    /// A top-left-origin rect (CG / Accessibility) in AppKit screen coordinates, matched to the
    /// screen it mostly lies on.
    private func appKitFrame(fromGlobalTopLeftFrame frame: CGRect) -> CGRect {
        let screens = NSScreen.screens.compactMap { screen -> (frame: CGRect, cgBounds: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (frame: screen.frame, cgBounds: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)))
        }
        let matched = screens
            .filter { $0.cgBounds.intersects(frame) }
            .max { lhs, rhs in
                lhs.cgBounds.intersection(frame).width * lhs.cgBounds.intersection(frame).height
                    < rhs.cgBounds.intersection(frame).width * rhs.cgBounds.intersection(frame).height
            }
        guard let matched else { return frame }
        let localX = frame.minX - matched.cgBounds.minX
        let localY = frame.minY - matched.cgBounds.minY
        return CGRect(x: matched.frame.minX + localX, y: matched.frame.maxY - localY - frame.height - 3,
                      width: frame.width, height: frame.height)
    }

    /// Stops only after repeated misses, so one failed lookup never closes the panel.
    private func finishTrackingIfNeededBecauseAppExited() {
        guard hasActiveTrackingTarget || currentFrame != nil else { return }
        missingAppPollCount += 1
        guard missingAppPollCount >= missingAppThreshold else { return }
        stopTracking()
        onTrackingEnded?()
    }
}
