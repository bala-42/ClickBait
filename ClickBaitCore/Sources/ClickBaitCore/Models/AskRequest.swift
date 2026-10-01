import Foundation

/// What was on screen when the user asked, beyond the pixels.
public struct ScreenContext: Equatable, Sendable {
    public var appName: String?
    public var windowTitle: String?
    /// e.g. `AXButton "Share"` — filled in once the accessibility inspector exists.
    public var focusedElement: String?

    public init(appName: String? = nil, windowTitle: String? = nil, focusedElement: String? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusedElement = focusedElement
    }
}

/// Everything a provider needs for one ask.
public struct AskRequest: Sendable {
    public var question: String
    /// JPEG of the downscaled screenshot (long edge ≤ 1280 px).
    public var screenshotJPEG: Data
    /// Pixel size of `screenshotJPEG`; pointer coordinates come back in this space.
    public var screenshotWidth: Int
    public var screenshotHeight: Int
    public var context: ScreenContext

    public init(question: String, screenshotJPEG: Data, screenshotWidth: Int, screenshotHeight: Int, context: ScreenContext) {
        self.question = question
        self.screenshotJPEG = screenshotJPEG
        self.screenshotWidth = screenshotWidth
        self.screenshotHeight = screenshotHeight
        self.context = context
    }
}
