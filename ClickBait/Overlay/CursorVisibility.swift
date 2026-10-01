import Foundation

/// Whether macOS is currently showing the mouse pointer, system-wide.
///
/// There's no public API for this (the public `CGCursorIsVisible` only ever described
/// the calling app and is gone from the SDK), so this uses SkyLight's private,
/// read-only `SLSCursorIsVisible`, loaded at runtime. If a future macOS removes it,
/// `isVisible()` returns nil and callers fall back to their own heuristics.
enum CursorVisibility {
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias VisibleFunction = @convention(c) (Int32) -> Bool

    private static let functions: (connection: ConnectionFunction, visible: VisibleFunction)? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(skyLight, "SLSMainConnectionID"),
              let visible = dlsym(skyLight, "SLSCursorIsVisible")
        else { return nil }
        return (unsafeBitCast(connection, to: ConnectionFunction.self), unsafeBitCast(visible, to: VisibleFunction.self))
    }()

    static var isAvailable: Bool { functions != nil }

    static func isVisible() -> Bool? {
        guard let functions else { return nil }
        return functions.visible(functions.connection())
    }
}
