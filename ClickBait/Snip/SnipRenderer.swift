import ClickBaitCore
import CoreGraphics
import Foundation

/// Turns a snip into what the model sees: a clean close-up of exactly what was marked
/// (no outline: small models describe a drawn outline instead of the thing inside it),
/// plus a small picture of the whole screen with the area boxed, for context.
enum SnipRenderer {
    /// The marked area with a little room around it, at full resolution.
    static func closeUp(_ capture: ScreenCapture, region: Rect) throws -> CGImage {
        let local = displayLocal(region, in: capture)
        let crop = SnipLayout.crop(around: local, displayWidth: capture.displayFrame.width, displayHeight: capture.displayFrame.height)
        let scale = Double(capture.image.width) / capture.displayFrame.width
        let pixelCrop = CGRect(x: crop.x * scale, y: crop.y * scale, width: crop.width * scale, height: crop.height * scale).integral
        guard let cropped = capture.image.cropping(to: pixelCrop) else { throw CocoaError(.coderInvalidValue) }
        return cropped
    }

    /// The whole display, small (long edge `contextLongEdge`), with a thin box around the
    /// marked area so the model can tell where on screen it was.
    static let contextLongEdge = 768.0

    static func context(_ capture: ScreenCapture, region: Rect) throws -> CGImage {
        let image = capture.image
        let factor = contextLongEdge / Double(max(image.width, image.height))
        let width = Int((Double(image.width) * factor).rounded()), height = Int((Double(image.height) * factor).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.coderInvalidValue) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Display points → this small image's pixels (CoreGraphics' origin is bottom-left).
        let local = displayLocal(region, in: capture)
        let perPoint = Double(width) / capture.displayFrame.width
        let box = CGRect(x: local.x * perPoint, y: Double(height) - (local.y + local.height) * perPoint,
                         width: local.width * perPoint, height: local.height * perPoint).insetBy(dx: -3, dy: -3)
        context.setStrokeColor(CGColor(srgbRed: 0.98, green: 0.22, blue: 0.36, alpha: 1))
        context.setLineWidth(2)
        context.stroke(box)
        guard let result = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        return result
    }

    /// Global Quartz points → the captured display's top-left-origin points.
    private static func displayLocal(_ region: Rect, in capture: ScreenCapture) -> Rect {
        let displayTop = capture.primaryDisplayHeight - capture.displayFrame.maxY
        return Rect(x: region.x - capture.displayFrame.minX, y: region.y - displayTop, width: region.width, height: region.height)
    }
}
