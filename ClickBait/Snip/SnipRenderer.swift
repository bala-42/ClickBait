import ClickBaitCore
import CoreGraphics
import Foundation

/// Turns a snip into the image the model sees: the marked area cropped out of the
/// screenshot with some context around it, and the user's circle or box drawn on it in
/// red so the model knows exactly what they meant.
enum SnipRenderer {
    static func render(_ capture: ScreenCapture, kind: SnipKind, region: Rect, path: [Point]) throws -> CGImage {
        // Global Quartz points → this display's top-left-origin points.
        let displayTop = capture.primaryDisplayHeight - capture.displayFrame.maxY
        let toDisplay = { (p: Point) in Point(x: p.x - capture.displayFrame.minX, y: p.y - displayTop) }
        let regionOrigin = toDisplay(Point(x: region.x, y: region.y))
        let crop = SnipLayout.crop(
            around: Rect(x: regionOrigin.x, y: regionOrigin.y, width: region.width, height: region.height),
            displayWidth: capture.displayFrame.width, displayHeight: capture.displayFrame.height
        )
        let scale = Double(capture.image.width) / capture.displayFrame.width
        let pixelCrop = CGRect(x: crop.x * scale, y: crop.y * scale, width: crop.width * scale, height: crop.height * scale).integral
        guard let cropped = capture.image.cropping(to: pixelCrop),
              let context = CGContext(
                  data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.coderInvalidValue) }

        let height = CGFloat(cropped.height)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        // Display points → pixels in the crop (CoreGraphics' origin is bottom-left).
        let toCrop = { (p: Point) -> CGPoint in
            let d = toDisplay(p)
            return CGPoint(x: d.x * scale - pixelCrop.minX, y: height - (d.y * scale - pixelCrop.minY))
        }
        context.setStrokeColor(CGColor(srgbRed: 0.98, green: 0.22, blue: 0.36, alpha: 1))
        context.setLineWidth(max(3, 2 * scale))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let points = path.map(toCrop)
        guard let first = points.first else { throw CocoaError(.coderInvalidValue) }
        context.move(to: first)
        points.dropFirst().forEach { context.addLine(to: $0) }
        if kind == .boxed { context.closePath() }
        context.strokePath()
        guard let image = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        return image
    }
}
