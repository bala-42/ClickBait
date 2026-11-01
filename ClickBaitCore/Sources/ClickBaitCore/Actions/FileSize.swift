import Foundation

/// A file size said in words: "200 MB", "under 5 megs", "1.5gb", "500 kilobytes" (user's report,
/// 2026-11-02: "it is not respecting the file size i request"). Decimal units, as Finder shows.
public enum FileSize {
    private static let units: [(words: [String], bytes: Double)] = [
        (["kb", "k", "kilobyte", "kilobytes", "kbs"], 1_000),
        (["mb", "meg", "megs", "megabyte", "megabytes", "mbs", "m"], 1_000_000),
        (["gb", "gig", "gigs", "gigabyte", "gigabytes", "gbs", "g"], 1_000_000_000),
    ]

    /// The first size in `text`, in bytes; nil when none is said.
    public static func bytes(in text: String) -> Int64? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*([a-z]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let lower = text.lowercased()
        for match in regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            guard let numberRange = Range(match.range(at: 1), in: lower), let unitRange = Range(match.range(at: 2), in: lower),
                  let number = Double(lower[numberRange].replacingOccurrences(of: ",", with: ".")), number > 0,
                  let unit = units.first(where: { $0.words.contains(String(lower[unitRange])) }) else { continue }
            return Int64(number * unit.bytes)
        }
        return nil
    }

    public static func label(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
