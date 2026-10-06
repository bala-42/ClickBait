import ClickBaitCore
import CoreGraphics
import Foundation

/// Turns a snip into what the model sees: a clean close-up of exactly what was marked
/// (no outline: small models describe a drawn outline instead of the thing inside it).
enum SnipRenderer {
    /// The close-up as sent to the model: scaled so its long edge is 1280 px, the size
    /// the local vision model places things accurately at (other sizes drift). Knows
    /// which part of the screen it shows, so positions in it map back to the screen.
    static func view(_ capture: ScreenCapture, region: Rect) throws -> SnipView {
        let local = displayLocal(region, in: capture)
        let crop = SnipLayout.crop(around: local, displayWidth: capture.displayFrame.width, displayHeight: capture.displayFrame.height)
        let scale = Double(capture.image.width) / capture.displayFrame.width
        let pixelCrop = CGRect(x: crop.x * scale, y: crop.y * scale, width: crop.width * scale, height: crop.height * scale).integral
        guard let cropped = capture.image.cropping(to: pixelCrop) else { throw CocoaError(.coderInvalidValue) }
        let factor = SnipView.longEdge / Double(max(cropped.width, cropped.height))
        let width = Int((Double(cropped.width) * factor).rounded()), height = Int((Double(cropped.height) * factor).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.coderInvalidValue) }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        let displayTop = capture.primaryDisplayHeight - capture.displayFrame.maxY
        let perPoint = Double(width) / crop.width
        return SnipView(
            image: image,
            crop: Rect(x: crop.x + capture.displayFrame.minX, y: crop.y + displayTop, width: crop.width, height: crop.height),
            marked: Rect(x: (local.x - crop.x) * perPoint, y: (local.y - crop.y) * perPoint,
                         width: local.width * perPoint, height: local.height * perPoint),
            primaryDisplayHeight: capture.primaryDisplayHeight)
    }

    /// Global Quartz points → the captured display's top-left-origin points.
    private static func displayLocal(_ region: Rect, in capture: ScreenCapture) -> Rect {
        let displayTop = capture.primaryDisplayHeight - capture.displayFrame.maxY
        return Rect(x: region.x - capture.displayFrame.minX, y: region.y - displayTop, width: region.width, height: region.height)
    }
}

/// A snip's close-up as the model sees it, and how its pixels map back to the screen.
struct SnipView: @unchecked Sendable {
    static let longEdge = 1280.0
    /// Immutable; CGImage just isn't annotated Sendable.
    let image: CGImage
    /// The part of the screen shown, in global Quartz points.
    let crop: Rect
    /// What the user marked, in the image's pixels.
    let marked: Rect
    let primaryDisplayHeight: Double

    func screenPointer(_ part: Pointer) -> ScreenPointer {
        let perPoint = Double(image.width) / crop.width
        let quartz = Point(x: crop.x + part.x / perPoint, y: crop.y + part.y / perPoint)
        return ScreenPointer(label: part.label, appKit: Point(x: quartz.x, y: primaryDisplayHeight - quartz.y), quartz: quartz)
    }

    /// The outline of the thing at each part (`PartOutline`), in screen points; nil where
    /// nothing separate stands out. Worked out on a copy at most 320 px long (a few ms;
    /// edges within ~2 pt).
    func outlines(at parts: [Pointer]) -> [PartOutline?] {
        let factor = min(1, 320 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return parts.map { _ in nil } }
        let scaleX = Double(width) / Double(image.width), scaleY = Double(height) / Double(image.height)
        let marked = Rect(x: marked.x * scaleX, y: marked.y * scaleY, width: marked.width * scaleX, height: marked.height * scaleY)
        // Small-copy pixels → screen points.
        let pointsPerPixel = crop.width / Double(width)
        return parts.map { part in
            PartOutline.find(rgba: pixels, width: width, height: height, bytesPerRow: width * 4,
                             at: Point(x: part.x * scaleX, y: part.y * scaleY), marked: marked)?
                .scaled(by: pointsPerPixel)
        }
    }
}
