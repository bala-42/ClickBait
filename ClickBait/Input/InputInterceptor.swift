import AppKit

/// Input ClickBait has to *take* rather than just watch (a global monitor can only
/// watch), through an event tap allowed by the Accessibility permission:
/// - Esc, only while ClickBait is busy, so it stops ClickBait without also closing a
///   dialog or leaving full screen in the app in front.
/// - ⌥⌘ + right-click: opens a chat to type into, without the app's context menu.
/// Everything else passes through untouched.
@MainActor
final class InputInterceptor {
    /// Whether Esc belongs to ClickBait right now.
    var isBusy: () -> Bool = { false }
    /// Called (on the main thread) for an Esc that was taken.
    var onEscape: () -> Void = {}
    /// ⌥⌘ + right-click: ask by typing.
    var onTypeToAsk: () -> Void = {}
    /// The matching right-mouse-up is taken too, so the app never sees half a click.
    fileprivate var swallowRightMouseUp = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// False if the tap couldn't be made (no Accessibility permission yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: escapeTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.input.error("Esc interceptor unavailable (Accessibility not granted?)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    /// macOS switches a tap off if it ever answers too slowly; switch it back on.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

/// Runs on the main run loop (where the tap's source was added), so main-actor state
/// can be read directly. Must answer quickly: anything slow is dispatched.
private func escapeTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<InputInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { interceptor.reenable() }
        return Unmanaged.passUnretained(event)
    }
    if type == .rightMouseDown || type == .rightMouseUp {
        let flags = event.flags
        let chord = flags.contains(.maskAlternate) && flags.contains(.maskCommand)
            && !flags.contains(.maskControl) && !flags.contains(.maskShift)
        let taken = MainActor.assumeIsolated { () -> Bool in
            if type == .rightMouseUp {
                defer { interceptor.swallowRightMouseUp = false }
                return interceptor.swallowRightMouseUp
            }
            guard chord else { return false }
            interceptor.swallowRightMouseUp = true
            DispatchQueue.main.async { interceptor.onTypeToAsk() }
            return true
        }
        return taken ? nil : Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
        return Unmanaged.passUnretained(event)
    }
    let taken = MainActor.assumeIsolated { () -> Bool in
        guard interceptor.isBusy() else { return false }
        Log.input.notice("Esc taken from the front app (ClickBait busy)")
        DispatchQueue.main.async { interceptor.onEscape() }
        return true
    }
    return taken ? nil : Unmanaged.passUnretained(event)
}
