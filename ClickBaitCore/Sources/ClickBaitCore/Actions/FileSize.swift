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
        let lower = digits(text.lowercased())
        for match in regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            guard let numberRange = Range(match.range(at: 1), in: lower), let unitRange = Range(match.range(at: 2), in: lower),
                  let number = Double(lower[numberRange].replacingOccurrences(of: ",", with: ".")), number > 0,
                  let unit = units.first(where: { $0.words.contains(String(lower[unitRange])) }) else { continue }
            return Int64(number * unit.bytes)
        }
        return nil
    }

    private static let small: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Numbers said in words become digits: "fifty megabytes" → "50 megabytes", "two hundred
    /// mb" → "200 mb" (speech-to-text writes either).
    static func digits(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        let bare = words.map { $0.trimmingCharacters(in: .punctuationCharacters) }
        var out: [String] = [], value = 0, inNumber = false
        for (index, word) in words.enumerated() {
            let next = index + 1 < bare.count ? bare[index + 1] : ""
            if bare[index] == "a", !inNumber, next == "hundred" || next == "thousand" {
                value = 1; inNumber = true  // "a hundred mb"
            } else if bare[index] != "a", let number = small[bare[index]] {
                value += number; inNumber = true
            } else if bare[index] == "hundred", inNumber {
                value *= 100
            } else if bare[index] == "thousand", inNumber {
                value *= 1000
            } else if bare[index] == "and", inNumber, small[next] != nil {
                continue
            } else {
                if inNumber { out.append(String(value)) }
                (value, inNumber) = (0, false)
                out.append(word)
            }
        }
        if inNumber { out.append(String(value)) }
        return out.joined(separator: " ")
    }

    public static func label(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
