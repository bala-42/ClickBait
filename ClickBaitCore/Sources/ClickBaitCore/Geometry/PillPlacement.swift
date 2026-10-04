/// Where a pill goes beside the companion so it stays fully on screen. Coordinates
/// are AppKit-style (y grows upward); `bounds` is the screen's visible area.
public enum PillPlacement {
    /// The pill's left edge and top edge. It sits beside `center` on the preferred side,
    /// vertically centered on it; if that side runs off screen it takes the other side,
    /// and whatever still doesn't fit is pushed inside `bounds` (minus `margin`).
    public static func beside(_ center: Point, width: Double, height: Double, gap: Double, preferRight: Bool,
                              bounds: Rect, margin: Double = 4) -> (x: Double, top: Double) {
        let minX = bounds.minX + margin, maxX = bounds.maxX - margin
        let minY = bounds.minY + margin, maxY = bounds.maxY - margin
        let right = center.x + gap, left = center.x - gap - width
        var x: Double
        if preferRight {
            x = right + width <= maxX ? right : (left >= minX ? left : right)
        } else {
            x = left >= minX ? left : (right + width <= maxX ? right : left)
        }
        x = min(max(x, minX), max(maxX - width, minX))
        var top = center.y + height / 2
        top = min(max(top, minY + height), maxY)
        return (x, top)
    }
}
