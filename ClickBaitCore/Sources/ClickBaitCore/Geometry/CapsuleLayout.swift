/// Top-right capsule slots in AppKit coordinates (the origin may be negative on a display).
public enum CapsuleLayout {
    public static let maxCapsules = 3
    public static let capsuleWidth = 44.0
    public static let capsuleHeight = 28.0
    public static let gap = 6.0
    public static let topInset = 8.0
    public static let rightInset = 8.0
    public static let cardWidth = 280.0
    public static let cardGap = 6.0

    public static func slot(_ index: Int, in visible: Rect) -> Rect? {
        guard (0..<maxCapsules).contains(index) else { return nil }
        return Rect(
            x: visible.maxX - rightInset - capsuleWidth,
            y: visible.maxY - topInset - capsuleHeight - Double(index) * (capsuleHeight + gap),
            width: capsuleWidth,
            height: capsuleHeight
        )
    }

    public static func card(under slot: Rect, height: Double, in visible: Rect) -> Rect {
        let width = min(cardWidth, visible.width - 16)
        let x = min(max(slot.maxX - width, visible.minX + 8), visible.maxX - width - 8)
        let top = slot.minY - cardGap
        let y = max(visible.minY + 8, top - height)
        return Rect(x: x, y: y, width: width, height: min(height, top - y))
    }
}
