import Foundation

/// Whether the screen is still exactly as it was, from small grey thumbnails: strict, since
/// a follow-up on an "unchanged" screen reuses the old screenshot. Any visible change (a new
/// line of text, a blinking caret) counts as changed, and a fresh screenshot is sent as before.
public enum ScreenChange {
    public static let width = 192
    public static let height = 108
    /// Grey levels a thumbnail pixel may differ by and still match (compression noise).
    public static let tolerance = 6

    public static func same(_ before: [UInt8], _ after: [UInt8]) -> Bool {
        guard before.count == width * height, before.count == after.count else { return false }
        return zip(before, after).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }
}
