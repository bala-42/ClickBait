import AppKit

/// Takes Esc away from the app in front while ClickBait is busy, so pressing it stops
/// ClickBait without also closing a dialog, leaving full screen or stopping something
/// in that app. A global key monitor can only watch; this is a key-event tap (allowed
/// by the Accessibility permission). While ClickBait is idle every key passes through
/// untouched.
@MainActor
final class EscapeInterceptor {
    /// Whether Esc belongs to ClickBait right now.
    var isBusy: () -> Bool = { false }
    /// Called (on the main thread) for an Esc that was taken.
    var onEscape: () -> Void = {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// False if the tap couldn't be made (no Accessibility permission yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
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
    let interceptor = Unmanaged<EscapeInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { interceptor.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
        return Unmanaged.passUnretained(event)
    }
    let taken = MainActor.assumeIsolated { () -> Bool in
        guard interceptor.isBusy() else { return false }
        DispatchQueue.main.async { interceptor.onEscape() }
        return true
    }
    return taken ? nil : Unmanaged.passUnretained(event)
}
