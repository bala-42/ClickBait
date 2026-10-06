import Foundation

/// How far the edge of the thing at a part's point is, in each direction, so a parts tour
/// can stop the triangle's tip at the thing's edge instead of on top of it (user's request,
/// 2026-10-06). Found on-device by growing the region of similar colour around the point;
/// Apple Vision's object finders missed small separate things (planets) entirely.
public struct PartOutline: Equatable, Sendable {
    public static let directions = 16

    /// Distance from the point to the edge for direction `i`, at `i × 360°/directions`
    /// counter-clockwise from +x, with y pointing up (AppKit's screen convention).
    public var radii: [Double]

    public init(radii: [Double]) {
        self.radii = radii
    }

    /// The edge's distance toward (`dx`, `dy`) (y up), between the two nearest directions.
    public func radius(toward dx: Double, _ dy: Double) -> Double {
        guard radii.count == Self.directions, dx != 0 || dy != 0 else { return 0 }
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }
        let position = angle / (2 * .pi) * Double(Self.directions)
        let lower = Int(position) % Self.directions
        let upper = (lower + 1) % Self.directions
        let fraction = position - Double(Int(position))
        return radii[lower] * (1 - fraction) + radii[upper] * fraction
    }

    public func scaled(by factor: Double) -> PartOutline {
        PartOutline(radii: radii.map { $0 * factor })
    }

    /// Colours this close (sum of the R, G and B differences) to the colour at the point
    /// count as the same thing.
    static let tolerance = 60
    /// A region larger than this share of the marked area isn't one separate thing (a part
    /// of a larger drawing, or a point that landed on the background): no outline.
    static let largestShare = 0.2
    /// Fewer pixels than this is noise (a point on a thin line or a speck).
    static let smallestRegion = 12

    /// The outline of the thing at `seed` in an RGBA image (8 bits per channel, rows top to
    /// bottom, `seed` and `marked` in its pixels), with radii in those pixels; nil when no
    /// separate thing is there.
    public static func find(rgba pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int,
                            at seed: Point, marked: Rect) -> PartOutline? {
        let sx = Int(seed.x.rounded(.down)), sy = Int(seed.y.rounded(.down))
        guard width > 0, height > 0, sx >= 0, sy >= 0, sx < width, sy < height,
              pixels.count >= bytesPerRow * height else { return nil }

        // The thing's colour: the average of the 3×3 pixels at the point, so one odd pixel
        // doesn't decide (5×5 reached past the edge of a small planet and missed it).
        var sum = (0, 0, 0), count = 0
        for y in max(0, sy - 1)...min(height - 1, sy + 1) {
            for x in max(0, sx - 1)...min(width - 1, sx + 1) {
                let i = y * bytesPerRow + x * 4
                sum = (sum.0 + Int(pixels[i]), sum.1 + Int(pixels[i + 1]), sum.2 + Int(pixels[i + 2]))
                count += 1
            }
        }
        let colour = (sum.0 / count, sum.1 / count, sum.2 / count)
        func matches(_ x: Int, _ y: Int) -> Bool {
            let i = y * bytesPerRow + x * 4
            return abs(Int(pixels[i]) - colour.0) + abs(Int(pixels[i + 1]) - colour.1)
                + abs(Int(pixels[i + 2]) - colour.2) <= tolerance
        }
        guard matches(sx, sy) else { return nil }

        let limit = max(Int(marked.width * marked.height * largestShare), smallestRegion)
        var inside = [Bool](repeating: false, count: width * height)
        var queue = [sy * width + sx]
        inside[sy * width + sx] = true
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            if queue.count > limit { return nil }
            let x = index % width, y = index / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height && !inside[ny * width + nx] && matches(nx, ny) {
                inside[ny * width + nx] = true
                queue.append(ny * width + nx)
            }
        }
        guard queue.count >= smallestRegion else { return nil }

        // March out from the point in each direction until leaving the region.
        let radii = (0..<directions).map { direction -> Double in
            let angle = Double(direction) * 2 * .pi / Double(directions)
            let dx = cos(angle), dy = -sin(angle)  // image rows run downward
            var distance = 0.0
            while true {
                let next = distance + 0.5
                let x = Int((seed.x + dx * next).rounded(.down)), y = Int((seed.y + dy * next).rounded(.down))
                guard x >= 0, y >= 0, x < width, y < height, inside[y * width + x] else { break }
                distance = next
            }
            return distance
        }
        return PartOutline(radii: radii)
    }
}
