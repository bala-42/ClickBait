import Foundation

/// Morning cards (user's choice, 2026-10-21; idea from Sentient OS's proactive cards): once a
/// day, on the first launch or wake after `startHour`, the local model reads today's reminders
/// and events and the user's remembered facts and offers up to `maxCount` short things to ask
/// ClickBait. Nothing runs until the user taps one. Pure: when it's due, the brief the model
/// reads, and its reply.
///
///     MorningCards.isDue(now: eightAM, lastShown: yesterday)   // true
public enum MorningCards {
    public static let startHour = 5
    public static let maxCount = 3
    /// A card's pill is 20 pt tall in a 260 pt card: longer ones are dropped, not cut.
    public static let maxLength = 40

    public struct Item: Equatable, Sendable {
        public var title: String
        public var time: Date?
        public init(title: String, time: Date?) {
            self.title = title
            self.time = time
        }
    }

    /// After `startHour` today, and not yet shown today.
    public static func isDue(now: Date, lastShown: Date?, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.hour, from: now) >= startHour else { return false }
        guard let lastShown else { return true }
        return !calendar.isDate(lastShown, inSameDayAs: now)
    }

    /// What the model reads, or nil with nothing to go on (then no cards).
    public static func brief(reminders: [Item], events: [Item], facts: [String], now: Date,
                             calendar: Calendar = .current) -> String? {
        guard !(reminders.isEmpty && events.isEmpty && facts.isEmpty) else { return nil }
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateFormat = "EEEE d MMMM"
        func line(_ item: Item) -> String { "- " + item.title + (item.time.map { " (\(time.string(from: $0)))" } ?? "") }
        var parts = ["Today is \(day.string(from: now))."]
        if !events.isEmpty { parts.append("Today's events:\n" + events.prefix(10).map(line).joined(separator: "\n")) }
        if !reminders.isEmpty { parts.append("Reminders due today or overdue:\n" + reminders.prefix(10).map(line).joined(separator: "\n")) }
        if !facts.isEmpty { parts.append("What they asked ClickBait to remember:\n" + facts.prefix(10).map { "- " + $0 }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// The cards in a `{"cards": [...]}` reply: trimmed, at most `maxCount`, none empty, too
    /// long or repeated. Nil for a reply that isn't one.
    public static func parse(_ reply: String) -> [String]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let cards = object["cards"] as? [Any] else { return nil }
        var seen: Set<String> = []
        var kept: [String] = []
        for case let item as String in cards {
            let text = item.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
            let key = NextSuggestions.normalized(text)
            guard !text.isEmpty, text.count <= maxLength, seen.insert(key).inserted else { continue }
            kept.append(text.prefix(1).uppercased() + text.dropFirst())
            if kept.count == maxCount { break }
        }
        return kept
    }
}
