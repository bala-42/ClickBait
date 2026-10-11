import Foundation

/// When a guided stop has really arrived, and how long it then holds. Every hold is timed
/// from arrival: timed from setting off, a blue point left ~1 s after starting its 0.6–1.4 s
/// flight (2026-10-11).
public enum GuideTiming {
    /// A single blue target holds this long after arriving.
    public static let singlePointHold: Double = 3
    /// Each of several blue targets holds this long after arriving.
    public static let multiPointHold: Double = 2
    /// Each part of a red tour holds this long after arriving.
    public static let tourHold: Double = 2.4
    /// A safety cap from setting off, should a stop never settle (targets kept being
    /// corrected): longer than the longest flight (1.4 s) + a final turn + the longest hold.
    public static let maxStop: Double = 12
    /// Close enough to the final spot to count as there (pt).
    public static let spotTolerance: Double = 0.5

    /// How long a stop holds after arriving, or nil for a walkthrough step (it waits for a click).
    public static func hold(isTour: Bool, isTutorial: Bool, targetCount: Int) -> Double? {
        if isTutorial { return nil }
        if isTour { return tourHold }
        return targetCount > 1 ? multiPointHold : singlePointHold
    }

    /// Arrived: the flight is over (or there is none, as with Reduce Motion), the triangle is
    /// at its final spot, and it has finished turning onto the target.
    public static func hasArrived(flightProgress: Double?, distanceToSpot: Double, isTurning: Bool) -> Bool {
        (flightProgress ?? 1) >= 1 && distanceToSpot <= spotTolerance && !isTurning
    }
}
