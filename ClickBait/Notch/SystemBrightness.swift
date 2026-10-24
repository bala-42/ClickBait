import CoreGraphics
import Foundation

/// The built-in screen's brightness (0…1), through DisplayServices: Apple's own framework for
/// it, private (macOS has no public call). Looked up at run time, so if a macOS update removes
/// it, reading fails and the brightness keys go to macOS untouched, as before.
enum SystemBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let calls: (get: Get, set: Set)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: Get.self), unsafeBitCast(set, to: Set.self))
    }()

    /// The built-in display (the one with the notch); nil without one.
    private static var builtIn: CGDirectDisplayID? {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func read() -> Double? {
        guard let calls, let display = builtIn else { return nil }
        var level: Float = 0
        guard calls.get(display, &level) == 0 else { return nil }
        return Double(level)
    }

    static func write(_ level: Double) -> Bool {
        guard let calls, let display = builtIn else { return false }
        return calls.set(display, Float(min(1, max(0, level)))) == 0
    }
}
