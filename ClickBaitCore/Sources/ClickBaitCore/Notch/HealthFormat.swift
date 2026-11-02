import Foundation

/// The Health page's numbers in words (user's ask, 2026-11-02, after Vorssaint's System page).
public enum HealthFormat {
    /// "92 KB/s", "2.3 MB/s", "0 KB/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1_000_000_000 { return String(format: "%.1f GB/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        return "\(Int((value / 1000).rounded())) KB/s"
    }

    /// What the battery holds now against when new, as a percentage (nil without both).
    public static func batteryHealth(full: Int?, design: Int?) -> Int? {
        guard let full, let design, design > 0, full > 0 else { return nil }
        return min(100, Int((Double(full) / Double(design) * 100).rounded()))
    }

    /// macOS's thermal state in words.
    public static func heat(_ state: Int) -> String {
        ["cool", "warm", "hot", "very hot"][min(3, max(0, state))]
    }
}
