import Foundation

/// Identity numbers that must never be remembered (`Memory`) or leave the Mac in search words
/// (`QueryScrubber`): US Social Security numbers, Singapore NRIC/FIN, passport-style numbers
/// (one or two letters and 6–9 digits), and IBANs. Card numbers and keys are caught where
/// they already were. A regex backstop, idea from Sentient OS's PII scan. Pure.
///
///     PersonalData.contains("My passport is K1234567")   // true
///     PersonalData.contains("Flight SQ321 at 9")         // false
public enum PersonalData {
    struct Pattern {
        let regex: NSRegularExpression
        /// A match counts only with at least this many digits (keeps ordinary capitals out).
        var minDigits = 0
    }

    static let patterns: [Pattern] = [
        Pattern(regex: make(#"\b\d{3}-\d{2}-\d{4}\b"#)),                       // US Social Security number
        Pattern(regex: make(#"\b[STFGM]\d{7}[A-Z]\b"#, caseless: true)),       // Singapore NRIC / FIN
        Pattern(regex: make(#"\b[A-Z]{1,2}\d{6,9}[A-Z]?\b"#, caseless: true)), // passport-style: K1234567
        // IBAN: country, check digits, then groups of four (spaced or not); upper case only.
        Pattern(regex: make(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?\b"#), minDigits: 10),
    ]

    private static func make(_ pattern: String, caseless: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseless ? [.caseInsensitive] : [])
    }

    public static func contains(_ text: String) -> Bool {
        !ranges(in: text).isEmpty
    }

    /// `text` with each identity number replaced by a space.
    public static func removed(from text: String) -> String {
        var result = text
        for range in ranges(in: text).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            result.replaceSubrange(range, with: " ")
        }
        return result
    }

    /// Where the identity numbers are, not overlapping.
    static func ranges(in text: String) -> [Range<String.Index>] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Range<String.Index>] = []
        for pattern in patterns {
            for match in pattern.regex.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text),
                      text[range].filter(\.isNumber).count >= pattern.minDigits,
                      !found.contains(where: { $0.overlaps(range) }) else { continue }
                found.append(range)
            }
        }
        return found
    }
}
