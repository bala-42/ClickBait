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
        let scale = Double(capture.image.width) / capture.displayFrame.width
        // Enough real pixels to enlarge from: a wider crop on a standard-resolution display.
        let crop = SnipLayout.crop(around: local, displayWidth: capture.displayFrame.width, displayHeight: capture.displayFrame.height,
                                   minSide: SnipLayout.minSide(pixelsPerPoint: scale, longEdge: SnipView.longEdge))
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

    /// What the user marked, back in global Quartz points (the region the snip was made from).
    var markedOnScreen: Rect {
        let perPoint = Double(image.width) / crop.width
        return Rect(x: crop.x + marked.x / perPoint, y: crop.y + marked.y / perPoint,
                    width: marked.width / perPoint, height: marked.height / perPoint)
    }

    /// The close-up as a `SnipMatch.side`² greyscale thumbnail, for "is it still there?".
    var thumbnail: [UInt8] {
        let side = SnipMatch.side
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }

    func screenPointer(_ part: Pointer) -> ScreenPointer {
        let perPoint = Double(image.width) / crop.width
        let quartz = Point(x: crop.x + part.x / perPoint, y: crop.y + part.y / perPoint)
        return ScreenPointer(label: part.label, appKit: Point(x: quartz.x, y: primaryDisplayHeight - quartz.y), quartz: quartz)
    }

    /// The outline of the thing at each part (`OutlineFinder`), in screen points; nil where
    /// no separate thing is seen whole.
    func outlines(at parts: [Pointer]) -> [PartOutline?] {
        let pointsPerPixel = crop.width / Double(image.width)
        return parts.map { part in
            OutlineFinder.outline(in: image, at: Point(x: part.x, y: part.y))?.scaled(by: pointsPerPixel)
        }
    }
}
