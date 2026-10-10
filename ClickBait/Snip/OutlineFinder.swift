import ClickBaitCore
import CoreGraphics
import CoreVideo
import Vision

/// The outline of the thing at a tour part's point, on-device (Vision's subject masks), so
/// the triangle's tip stops at its edge (`PartOutline`).
///
/// Asked of a small crop around the point, where that thing is the subject: on the whole
/// close-up Vision saw only the big shapes. Scored on a real solar-system picture (8 planets,
/// 5 points each, 2026-10-06): 37/40 found, edges within 2.1 px typically (7% of the radius)
/// and 7 px for 90%, no outline on any of 9 points in space, on orbit lines or inside the
/// Sun; ~30 ms a part. Colour-matching from the point found 34/40 but stopped at Jupiter's
/// bands and Earth's clouds (edges 18.5 px off, 61% of the radius).
enum OutlineFinder {
    /// Crop sides tried in turn (close-up pixels; the close-up's long edge is 1280): the next
    /// when the thing runs off the crop, so it's only measured when seen whole.
    private static let cropSides: [Double] = [160, 320, 640]

    /// The outline in the image's pixels; nil when no separate thing is seen whole there.
    static func outline(in image: CGImage, at seed: Point) -> PartOutline? {
        for side in cropSides {
            if let outline = outline(in: image, at: seed, side: side) { return outline }
        }
        return nil
    }

    private static func outline(in image: CGImage, at seed: Point, side: Double) -> PartOutline? {
        let width = Double(image.width), height = Double(image.height)
        guard seed.x >= 0, seed.y >= 0, seed.x < width, seed.y < height else { return nil }
        let rect = CGRect(x: max(0, min(width - side, seed.x - side / 2)), y: max(0, min(height - side, seed.y - side / 2)),
                          width: min(side, width), height: min(side, height)).integral
        guard let crop = image.cropping(to: rect) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try VNImageRequestHandler(cgImage: crop).perform([request])
        } catch {
            Log.ask.error("Outline: Vision failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let observation = request.results?.first else { return nil }

        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let maskWidth = CVPixelBufferGetWidth(mask), maskHeight = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        let cropWidth = crop.width, cropHeight = crop.height
        let local = Point(x: seed.x - rect.minX, y: seed.y - rect.minY)
        func label(_ x: Int, _ y: Int) -> UInt8 {
            base[(y * maskHeight / cropHeight) * row + x * maskWidth / cropWidth]
        }
        let seedX = min(max(Int(local.x), 0), cropWidth - 1), seedY = min(max(Int(local.y), 0), cropHeight - 1)
        let instance = label(seedX, seedY)
        guard instance != 0 else { return nil }  // the point isn't on a subject
        var inside = [Bool](repeating: false, count: cropWidth * cropHeight)
        for y in 0..<cropHeight {
            for x in 0..<cropWidth where label(x, y) == instance { inside[y * cropWidth + x] = true }
        }
        // Running off the crop (not the picture's own edge): bigger than this crop; try the next.
        let runsOff = (rect.minX > 0 && (0..<cropHeight).contains { inside[$0 * cropWidth] })
            || (rect.maxX < width && (0..<cropHeight).contains { inside[$0 * cropWidth + cropWidth - 1] })
            || (rect.minY > 0 && (0..<cropWidth).contains { inside[$0] })
            || (rect.maxY < height && (0..<cropWidth).contains { inside[(cropHeight - 1) * cropWidth + $0] })
        guard !runsOff else { return nil }
        return PartOutline.from(mask: inside, width: cropWidth, height: cropHeight, seed: local)
    }
}
