import AppKit

/// Whether the user can currently see the mouse pointer, system-wide.
///
/// Two ways the pointer disappears, both covered:
/// - an app hides it (full-screen video, typing, games): there's no public API for
///   this, so SkyLight's private, read-only `SLSCursorIsVisible` is used (loaded at
///   runtime; user-approved);
/// - a web page sets an invisible cursor (`cursor: none`, e.g. YouTube in a normal
///   window): macOS still counts the pointer as visible, so the current system cursor
///   image (public `NSCursor.currentSystem`) is checked for transparency — only when
///   the cursor changes, tracked by SkyLight's cursor seed.
///
/// If the private functions are missing, `isVisible()` returns nil and callers fall
/// back to their own heuristics.
@MainActor
enum CursorVisibility {
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias VisibleFunction = @convention(c) (Int32) -> Bool
    private typealias SeedFunction = @convention(c) () -> Int32

    private static let functions: (connection: ConnectionFunction, visible: VisibleFunction, seed: SeedFunction?)? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(skyLight, "SLSMainConnectionID"),
              let visible = dlsym(skyLight, "SLSCursorIsVisible")
        else { return nil }
        let seed = dlsym(skyLight, "SLSCurrentCursorSeed").map { unsafeBitCast($0, to: SeedFunction.self) }
        return (unsafeBitCast(connection, to: ConnectionFunction.self), unsafeBitCast(visible, to: VisibleFunction.self), seed)
    }()

    private static var cachedSeed: Int32?
    private static var cachedTransparent = false
    /// Fetching the cursor image is a window-server round trip (it showed up in a sample
    /// of the stutters): at most twice a second, even when the cursor keeps changing.
    private static var lastImageCheck = Date.distantPast

    static var isAvailable: Bool { functions != nil }

    static func isVisible() -> Bool? {
        guard let functions else { return nil }
        guard functions.visible(functions.connection()) else { return false }
        return !isCursorImageTransparent(seed: functions.seed?())
    }

    /// Re-examines the cursor image only when it changes (or every call if the seed
    /// function is unavailable).
    private static func isCursorImageTransparent(seed: Int32?) -> Bool {
        if let seed, seed == cachedSeed { return cachedTransparent }
        guard Date().timeIntervalSince(lastImageCheck) >= 0.5 else { return cachedTransparent }
        lastImageCheck = Date()
        cachedSeed = seed
        cachedTransparent = NSCursor.currentSystem.map { isTransparent($0.image) } ?? false
        return cachedTransparent
    }

    private static func isTransparent(_ image: NSImage) -> Bool {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return false }
        let width = 32, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        // Alpha is every 4th byte; "transparent" means nothing above ~3% opacity.
        return !stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 8 }
    }
}
