import ClickBaitCore
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import os
import Vision

/// The separate things in a snip's close-up, found on this Mac (Vision's subject masks), so
/// a parts tour points at real things: the model only says which numbered mark is which
/// name (`ObjectMarks`).
///
/// Asked of overlapping crops of three sizes, since on the whole close-up Vision sees only
/// the big shapes. On a solar-system picture (2026-10-06) it found all eight planets within
/// a few pixels of their centres; the crops run side by side, and it starts when the snip
/// is made, so it's ready long before the explanation (~10 s).
enum ObjectFinder {
    private static let cropSides: [Double] = [160, 320, 640]
    private static let maxConcurrentCrops = 2
    /// The marked copy the model names marks on: 960 px on its long edge read in 2.4 s
    /// instead of 4.0 s at 1280 with the same answers (13/15, 15/15); at 768 it got 7/15.
    static let markedLongEdge = 960.0

    /// Shared with the cancellation handler so a synchronous Vision request can stop before
    /// starting another crop. A request already inside Vision finishes before the batch exits.
    final class CancellationFlag: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)

        var isCancelled: Bool { state.withLock { $0 } }
        func cancel() { state.withLock { $0 = true } }
    }

    static func objects(in image: CGImage, marked: Rect, cancellation: CancellationFlag) -> [FoundObject] {
        let width = Double(image.width), height = Double(image.height)
        // Only around what was marked (with the same slack the tour allows).
        let area = CGRect(x: marked.minX - marked.width * 0.1, y: marked.minY - marked.height * 0.1,
                          width: marked.width * 1.2, height: marked.height * 1.2)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isEmpty, !cancellation.isCancelled else { return [] }
        var crops: [CGRect] = [CGRect(x: 0, y: 0, width: width, height: height)]
        for side in cropSides {
            guard !cancellation.isCancelled else { return [] }
            let tileWidth = min(side, width), tileHeight = min(side, height)
            var y = area.minY
            while true {
                guard !cancellation.isCancelled else { return [] }
                var x = area.minX
                let top = max(0, min(y, height - tileHeight))
                while true {
                    guard !cancellation.isCancelled else { return [] }
                    let left = max(0, min(x, width - tileWidth))
                    crops.append(CGRect(x: left, y: top, width: tileWidth, height: tileHeight))
                    if left + tileWidth >= area.maxX { break }
                    x += side / 2
                }
                if top + tileHeight >= area.maxY { break }
                y += side / 2
            }
        }
        var allFound: [FoundObject] = []
        var start = 0
        while start < crops.count {
            guard !cancellation.isCancelled else { return [] }
            let end = min(start + maxConcurrentCrops, crops.count)
            let batch = Array(crops[start..<end])
            let found = OSAllocatedUnfairLock(initialState: [[FoundObject]](repeating: [], count: batch.count))
            DispatchQueue.concurrentPerform(iterations: batch.count) { index in
                guard !cancellation.isCancelled else { return }
                let seen = objects(in: image, crop: batch[index])
                found.withLock { $0[index] = seen }
            }
            allFound.append(contentsOf: found.withLock { $0.joined() })
            start = end
        }
        guard !cancellation.isCancelled else { return [] }
        return ObjectMarks.merge(allFound, imageWidth: width, imageHeight: height, marked: marked)
    }

    /// The things seen whole in one crop (one running off the crop's inner edges is left to
    /// a bigger crop), in the image's pixels.
    private static func objects(in image: CGImage, crop rect: CGRect) -> [FoundObject] {
        guard let crop = image.cropping(to: rect.integral) else { return [] }
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try VNImageRequestHandler(cgImage: crop).perform([request])
        } catch {
            Log.ask.error("Objects: Vision failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard let observation = request.results?.first else { return [] }
        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let maskWidth = CVPixelBufferGetWidth(mask), maskHeight = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        let imageWidth = Double(image.width), imageHeight = Double(image.height)
        let scaleX = rect.width / Double(maskWidth), scaleY = rect.height / Double(maskHeight)

        return observation.allInstances.compactMap { instance -> FoundObject? in
            var count = 0.0, sumX = 0.0, sumY = 0.0
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<maskHeight {
                for x in 0..<maskWidth where Int(base[y * row + x]) == instance {
                    count += 1
                    sumX += Double(x)
                    sumY += Double(y)
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard count > 0 else { return nil }
            let runsOff = (minX == 0 && rect.minX > 0) || (minY == 0 && rect.minY > 0)
                || (maxX == maskWidth - 1 && rect.maxX < imageWidth) || (maxY == maskHeight - 1 && rect.maxY < imageHeight)
            guard !runsOff else { return nil }
            let boxWidth = Double(maxX - minX + 1), boxHeight = Double(maxY - minY + 1)
            return FoundObject(center: Point(x: rect.minX + (sumX / count + 0.5) * scaleX, y: rect.minY + (sumY / count + 0.5) * scaleY),
                               width: boxWidth * scaleX, height: boxHeight * scaleY, fill: count / (boxWidth * boxHeight))
        }
    }

    /// A copy of the close-up with a numbered red badge by each thing (1 = `objects[0]`), for
    /// the model to name, `markedLongEdge` px on its long edge.
    static func marked(_ image: CGImage, objects: [FoundObject]) -> CGImage? {
        let scale = min(1, markedLongEdge / Double(max(image.width, image.height)))
        let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 17 * scale, nil)
        let radius = ObjectMarks.badgeRadius * scale
        for (index, object) in objects.enumerated() {
            let badge = ObjectMarks.badgeCenter(for: object)
            let center = CGPoint(x: badge.x * scale, y: Double(height) - badge.y * scale)  // CG's y runs up
            context.setFillColor(red: 1, green: 0.1, blue: 0.1, alpha: 1)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let number = NSAttributedString(string: "\(index + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            let line = CTLineCreateWithAttributedString(number)
            let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.textPosition = CGPoint(x: center.x - textWidth / 2, y: center.y - 6 * scale)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
}
