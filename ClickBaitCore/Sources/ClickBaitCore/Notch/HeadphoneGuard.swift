import Foundation

/// Sound leaving headphones for the Mac's speakers turns down (user's ask, 2026-11-02, after
/// Vorssaint's): unplugged or disconnected, what was private shouldn't blast into the room.
public enum HeadphoneGuard {
    public enum Output: Equatable, Sendable { case speakers, headphones, other }
    /// The level the speakers start at, at most.
    public static let quiet = 0.25

    /// The volume to set after the output changed, or nil to leave it.
    public static func volume(after current: Double, from old: Output, to new: Output) -> Double? {
        guard old == .headphones, new == .speakers, current > quiet else { return nil }
        return quiet
    }

    /// What an output is, from its transport ("blue", "usb ", "bltn") and, for the built-in one,
    /// its data source ("hdpn" headphones, "ispk" speakers).
    public static func kind(transport: String, dataSource: String?) -> Output {
        switch transport {
        case "blue", "usb ": return .headphones  // AirPods, headsets
        case "bltn": return dataSource == "hdpn" ? .headphones : .speakers
        default: return .other  // displays, AirPlay, aggregates: left alone
        }
    }
}
