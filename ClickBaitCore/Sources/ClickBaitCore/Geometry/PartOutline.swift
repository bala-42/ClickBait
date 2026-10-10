import Foundation

/// How far the edge of the thing at a part's point is, in each direction, so a parts tour
/// can stop the triangle's tip at the thing's edge instead of on top of it (user's request,
/// 2026-10-06). The shape comes from Apple Vision on the device (`OutlineFinder`); this is
/// the geometry: how far its edge is in each direction, and toward any direction.
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

    /// The outline of the shape `inside` (one flag per pixel, rows top to bottom) as seen
    /// from `seed`, with radii in those pixels: each direction's distance to where the shape ends.
    public static func from(mask inside: [Bool], width: Int, height: Int, seed: Point) -> PartOutline {
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
