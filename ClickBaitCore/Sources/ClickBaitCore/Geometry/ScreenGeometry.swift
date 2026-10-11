/// Platform-neutral point/rect (CoreGraphics isn't available to the portable core).
public struct Point: Equatable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var description: String { "(\(Self.format(x)), \(Self.format(y)))" }

    static func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxY: Double { y + height }
}

/// Maps between the screenshot the model saw and real screen positions.
///
/// Three coordinate spaces are involved:
/// - **Image pixels**: the downscaled JPEG sent to the model; origin top-left, y down.
/// - **AppKit global points**: what `NSWindow`/`NSScreen` use; origin at the bottom-left
///   of the primary display, y up. Other displays can have negative coordinates.
/// - **Quartz global points**: what Accessibility and `CGEvent` use; origin at the
///   top-left of the primary display, y down.
///
/// Scale is derived from the image size versus the display's size in points, which
/// folds the downscale factor and the Retina backing scale into one number per axis.
public struct ScreenGeometry: Equatable, Sendable {
    /// Size of the image the model saw, in pixels.
    public var imageWidth: Double
    public var imageHeight: Double
    /// The captured display's frame in AppKit global points.
    public var displayFrame: Rect
    /// Height of the primary display (the one with the menu bar at origin), in points.
    public var primaryDisplayHeight: Double

    public init(imageWidth: Int, imageHeight: Int, displayFrame: Rect, primaryDisplayHeight: Double) {
        self.imageWidth = Double(imageWidth)
        self.imageHeight = Double(imageHeight)
        self.displayFrame = displayFrame
        self.primaryDisplayHeight = primaryDisplayHeight
    }

    /// Points per image pixel on each axis.
    var scaleX: Double { displayFrame.width / imageWidth }
    var scaleY: Double { displayFrame.height / imageHeight }

    /// Image pixel → offset from the display's top-left, in points, kept on the display.
    private func displayOffset(ofImagePixel point: Point) -> Point {
        Point(
            x: min(max(point.x * scaleX, 0), displayFrame.width),
            y: min(max(point.y * scaleY, 0), displayFrame.height)
        )
    }

    public func appKitPoint(fromImagePixel point: Point) -> Point {
        let offset = displayOffset(ofImagePixel: point)
        return Point(x: displayFrame.minX + offset.x, y: displayFrame.maxY - offset.y)
    }

    public func quartzPoint(fromImagePixel point: Point) -> Point {
        let offset = displayOffset(ofImagePixel: point)
        return Point(x: displayFrame.minX + offset.x, y: primaryDisplayHeight - displayFrame.maxY + offset.y)
    }

    /// Quartz (Accessibility) point → AppKit point. Valid for any display.
    public func appKitPoint(fromQuartz point: Point) -> Point {
        Point(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// AppKit point → Quartz (Accessibility) point. Valid for any display.
    public func quartzPoint(fromAppKit point: Point) -> Point {
        Point(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// Quartz point → image pixel (inverse of `quartzPoint(fromImagePixel:)`).
    public func imagePixel(fromQuartz point: Point) -> Point {
        let offsetX = point.x - displayFrame.minX
        let offsetY = point.y - (primaryDisplayHeight - displayFrame.maxY)
        return Point(x: offsetX / scaleX, y: offsetY / scaleY)
    }
}
