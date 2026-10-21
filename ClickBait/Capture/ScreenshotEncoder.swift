import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The screenshot as sent to the model: long edge ≤ 1280 px, JPEG.
struct EncodedScreenshot: Sendable {
    let jpeg: Data
    let width: Int
    let height: Int
    /// Captured pixels per sent pixel (≥ 1). Pointer coordinates from the model are
    /// multiplied by this to get back to captured pixels.
    let downscale: Double
}

enum ScreenshotEncoder {
    static let maxLongEdge = 1280

    /// `encode`, off the main thread: a full Retina screenshot takes ~0.1–0.3 s to scale
    /// and compress, and on the main thread the companion froze for that long.
    static func encodeInBackground(_ image: CGImage) async throws -> EncodedScreenshot {
        let box = ImageBox(image: image)
        return try await Task.detached(priority: .userInitiated) { try encode(box.image) }.value
    }

    /// CGImage is immutable and thread-safe; it just isn't annotated Sendable.
    private struct ImageBox: @unchecked Sendable { let image: CGImage }

    /// `limit`: the sent long edge (`maxLongEdge`; `AskBench` tries others).
    static func encode(_ image: CGImage, longEdge limit: Int = maxLongEdge) throws -> EncodedScreenshot {
        let longEdge = max(image.width, image.height)
        let downscale = max(1, Double(longEdge) / Double(limit))
        let width = Int((Double(image.width) / downscale).rounded())
        let height = Int((Double(image.height) / downscale).rounded())

        let scaled: CGImage
        if downscale == 1 {
            scaled = image
        } else {
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw CocoaError(.coderInvalidValue) }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let result = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
            scaled = result
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.coderInvalidValue)
        }
        // UI text needs to stay legible to the model; 0.8 is a good size/clarity balance.
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.coderInvalidValue) }
        return EncodedScreenshot(jpeg: data as Data, width: width, height: height, downscale: downscale)
    }
}
