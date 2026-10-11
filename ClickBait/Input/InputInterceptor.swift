import AppKit
import ApplicationServices

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
    /// The key-up of a taken Esc is taken too (and its repeats), so the app never sees half
    /// a key press.
    fileprivate var swallowEscape = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?

    /// False if the tap couldn't be made (no Accessibility permission yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
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
        Log.input.notice("Esc interceptor on (listen \(CGPreflightListenEventAccess(), privacy: .public), post \(CGPreflightPostEventAccess(), privacy: .public), accessibility \(AXIsProcessTrusted(), privacy: .public))")
        // macOS can switch a tap off without telling it (a slow answer, or after sleep);
        // without it Esc would reach the app in front while ClickBait is busy.
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let tap = self?.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.input.notice("Esc interceptor was off; switched back on")
            }
        }
        return true
    }

    /// macOS switches a tap off if it ever answers too slowly; switch it back on.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        Log.input.notice("Esc interceptor switched off by macOS; back on")
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
    guard type == .keyDown || type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
        return Unmanaged.passUnretained(event)
    }
    let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    if type == .keyUp || repeated {
        let taken = MainActor.assumeIsolated { () -> Bool in
            let swallow = interceptor.swallowEscape
            if type == .keyUp { interceptor.swallowEscape = false }
            return swallow
        }
        return taken ? nil : Unmanaged.passUnretained(event)
    }
    let taken = MainActor.assumeIsolated { () -> Bool in
        interceptor.swallowEscape = false
        guard interceptor.isBusy() else {
            Log.input.notice("Esc passed to the front app (ClickBait idle)")
            return false
        }
        Log.input.notice("Esc taken from the front app (ClickBait busy)")
        interceptor.swallowEscape = true
        DispatchQueue.main.async { interceptor.onEscape() }
        return true
    }
    return taken ? nil : Unmanaged.passUnretained(event)
}
