import Foundation

/// Whether the screen still shows what was snipped, from two small greyscale thumbnails of
/// the same screen area (`side` × `side`, one byte a pixel, row by row). Used before a tour
/// that comes back from the dock: its stops are positions on the screen as it was, so after
/// a scroll, a moved window or another desktop they would point at the wrong things.
/// A blinking caret or a changed clock stays under the tolerance; a scroll does not.
public enum SnipMatch {
    public static let side = 32
    /// Mean absolute difference, in grey levels (0–255), up to which the two still match.
    public static let tolerance = 12.0

    public static func difference(_ before: [UInt8], _ after: [UInt8]) -> Double? {
        guard before.count == side * side, after.count == before.count else { return nil }
        var total = 0
        for index in before.indices { total += abs(Int(before[index]) - Int(after[index])) }
        return Double(total) / Double(before.count)
    }

    /// False when the thumbnails differ, or can't be compared (a wrong size).
    public static func matches(_ before: [UInt8], _ after: [UInt8]) -> Bool {
        guard let difference = difference(before, after) else { return false }
        return difference <= tolerance
    }
}
