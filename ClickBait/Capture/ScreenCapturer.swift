import AppKit
import ClickBaitCore
import ScreenCaptureKit

/// A full-resolution screenshot of one display plus what's needed to map pixels
/// back to global screen points later.
struct ScreenCapture: @unchecked Sendable {
    // CGImage is immutable and thread-safe; it just isn't annotated Sendable.
    let image: CGImage
    let displayID: CGDirectDisplayID
    /// The display's frame in global AppKit points (origin bottom-left of the main display).
    let displayFrame: CGRect
    let backingScale: CGFloat
    /// Height of the primary display in points, needed to convert to Quartz coordinates.
    let primaryDisplayHeight: CGFloat

    /// How to map pixels of a downscaled copy of this capture back onto the screen.
    func geometry(imageWidth: Int, imageHeight: Int) -> ScreenGeometry {
        ScreenGeometry(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            displayFrame: Rect(x: displayFrame.minX, y: displayFrame.minY, width: displayFrame.width, height: displayFrame.height),
            primaryDisplayHeight: primaryDisplayHeight
        )
    }
}

enum ScreenCaptureError: LocalizedError {
    case noDisplayUnderCursor
    case displayNotShareable

    var errorDescription: String? {
        switch self {
        case .noDisplayUnderCursor: "Couldn't tell which display the cursor is on."
        case .displayNotShareable: "macOS didn't allow capturing this display. Check Screen Recording permission."
        }
    }
}

/// Captures the display under the mouse cursor with ScreenCaptureKit, leaving out
/// ClickBait's own windows (overlay, bubble) and every window of a blocked app, even
/// one that is only visible in the background.
@MainActor
final class ScreenCapturer {
    func captureDisplayUnderCursor(excluding blocklist: AppBlocklist) async throws -> ScreenCapture {
        let mouse = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            throw ScreenCaptureError.noDisplayUnderCursor
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let displayFrame = screen.frame
        let backingScale = screen.backingScaleFactor
        // The primary display is always first and holds the global origin.
        let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? displayFrame.height

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotShareable
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter {
            $0.processID == ownPID || blocklist.isBlocked(bundleID: $0.bundleIdentifier)
        }

        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(displayFrame.width * backingScale)
        config.height = Int(displayFrame.height * backingScale)
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return ScreenCapture(
            image: image, displayID: displayID, displayFrame: displayFrame,
            backingScale: backingScale, primaryDisplayHeight: primaryDisplayHeight
        )
    }
}
