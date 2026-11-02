import Foundation

/// Watch (user's ask, 2026-11-02, after Vorssaint's): part of the screen, read every few seconds,
/// until it does what was asked — changes, finishes (changed, then held still, as a progress bar
/// or a log does when the work ends), shows some text ("Done"), or a number reaches a value,
/// counting up or down. The deciding only; the app captures and reads.
public struct ScreenWatch: Sendable {
    public enum Rule: Equatable, Sendable {
        case changes
        case finishes
        case says(String)
        case reaches(Double)

        public var summary: String {
            switch self {
            case .changes: "when it changes"
            case .finishes: "when it finishes"
            case .says(let text): "when it says “\(text)”"
            case .reaches(let value): "when it reaches \(value.formatted())"
            }
        }
    }

    public let rule: Rule
    /// Held still this long after changing counts as finished.
    public static let settle: TimeInterval = 10

    private var first: String?
    private var last: String?
    private var changedAt: Date?
    private var firstNumber: Double?

    public init(rule: Rule) { self.rule = rule }

    /// A new reading (the text read, or a picture's fingerprint where there's no text): why it's
    /// done, or nil to keep watching.
    public mutating func see(_ reading: String, at now: Date = Date()) -> String? {
        defer { last = reading }
        if first == nil {
            first = reading
            firstNumber = Self.number(in: reading)
        }
        let changed = last.map { $0 != reading } ?? false
        if changed { changedAt = now }
        switch rule {
        case .changes:
            return changed ? "it changed" : nil
        case .finishes:
            guard let changedAt, !changed, now.timeIntervalSince(changedAt) >= Self.settle else { return nil }
            return "it finished"
        case .says(let text):
            return reading.localizedCaseInsensitiveContains(text) ? "it says “\(text)”" : nil
        case .reaches(let target):
            guard let value = Self.number(in: reading) else { return nil }
            let up = (firstNumber ?? value) <= target
            return (up ? value >= target : value <= target) ? "it reached \(value.formatted())" : nil
        }
    }

    /// The first number in the text ("42%" → 42, "1,204 files" → 1204, "3.5 GB" → 3.5).
    public static func number(in text: String) -> Double? {
        guard let range = text.range(of: #"-?\d[\d,]*(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(text[range].replacingOccurrences(of: ",", with: ""))
    }
}
