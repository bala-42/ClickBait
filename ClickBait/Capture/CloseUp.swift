import ClickBaitCore
import CoreGraphics
import Foundation

/// A sharp close-up of the screenshot around a rough pointer, for a second look at
/// where exactly something is. Always 1280×800 px (640×400 pt at 2×): the size the
/// local vision model points accurately at — at other sizes its coordinates drift.
struct CloseUp {
    static let size = CGSize(width: 1280, height: 800)
    static let pixelsPerPoint = 2.0

    let image: CGImage
    /// The area shown, in global Quartz points.
    let region: Rect

    init(_ capture: ScreenCapture, around quartz: Point) throws {
        let display = capture.displayFrame
        let displayTop = capture.primaryDisplayHeight - display.maxY
        let width = Self.size.width / Self.pixelsPerPoint, height = Self.size.height / Self.pixelsPerPoint
        // Centered on the guess, kept inside the display (display-local points).
        let localX = min(max(quartz.x - display.minX - width / 2, 0), max(display.width - width, 0))
        let localY = min(max(quartz.y - displayTop - height / 2, 0), max(display.height - height, 0))
        let scale = Double(capture.image.width) / display.width
        let pixelRect = CGRect(x: localX * scale, y: localY * scale, width: width * scale, height: height * scale).integral
        guard let cropped = capture.image.cropping(to: pixelRect),
              let context = CGContext(
                  data: nil, width: Int(Self.size.width), height: Int(Self.size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.coderInvalidValue) }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(origin: .zero, size: Self.size))
        guard let image = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        self.image = image
        region = Rect(x: display.minX + localX, y: displayTop + localY, width: width, height: height)
    }

    /// A pixel of the close-up → global Quartz point.
    func quartzPoint(fromPixel x: Double, _ y: Double) -> Point {
        Point(x: region.x + x / Self.pixelsPerPoint, y: region.y + y / Self.pixelsPerPoint)
    }
}
