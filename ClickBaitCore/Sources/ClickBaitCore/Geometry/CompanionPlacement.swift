import Foundation

/// Where the companion rests by the cursor (AppKit points, y up): its triangle `offset` right
/// of and below the hotspot, as Clicky's (MIT). Near a screen edge it stops there, kept on the
/// screen, instead of moving to the other side of the cursor (user's rule, 2026-10-23,
/// replacing 2026-10-14's flip). Pure.
public enum CompanionPlacement {
    /// The companion's top-left for `mouse`. `offset`: the triangle's centre from the hotspot;
    /// `inContent`: the triangle's centre from the companion's top-left.
    public static func topLeft(mouse: Point, content: (width: Double, height: Double), bounds: Rect?,
                               offset: (width: Double, height: Double), inContent: Double) -> Point {
        var x = mouse.x + offset.width - inContent
        var y = mouse.y - offset.height + inContent
        if let bounds {
            x = max(bounds.minX, min(x, bounds.maxX - content.width))
            y = min(bounds.maxY, max(y, bounds.minY + content.height))
        }
        return Point(x: x, y: y)
    }
}
