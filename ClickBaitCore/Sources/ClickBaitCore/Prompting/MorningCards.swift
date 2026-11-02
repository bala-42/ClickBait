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
    public static func brief(reminders: [Item], events: [Item], facts: [String], now: Date, name: String? = nil,
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
        var parts = ["Today is \(day.string(from: now))." + (name.map { " Their name is \($0)." } ?? "")]
        if !events.isEmpty { parts.append("Today's events:\n" + events.prefix(10).map(line).joined(separator: "\n")) }
        if !reminders.isEmpty { parts.append("Reminders due today or overdue:\n" + reminders.prefix(10).map(line).joined(separator: "\n")) }
        if !facts.isEmpty { parts.append("What they asked ClickBait to remember:\n" + facts.prefix(10).map { "- " + $0 }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// The greeting in a `{"text": "..."}` reply (user's ask, 2026-11-02: the morning brief
    /// in the notch, "greeting me … only relevant information in natural language"): trimmed,
    /// at most `greetingLength` characters (cut at a sentence when longer). Nil when there isn't one.
    public static func greeting(from reply: String) -> String? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let raw = object["text"] as? String else { return nil }
        var text = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > greetingLength {
            let cut = String(text.prefix(greetingLength))
            text = cut.range(of: ".", options: .backwards).map { String(cut[...$0.lowerBound]) } ?? cut + "…"
        }
        return text
    }

    public static let greetingLength = 260

    /// When the model can't: a plain greeting from the same facts. "Good morning, Balaji. You
    /// have Atlas standup at 09:30, and Pay rent is due today."
    public static func plainGreeting(name: String?, reminders: [Item], events: [Item], now: Date,
                                     calendar: Calendar = .current) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        let hour = calendar.component(.hour, from: now)
        let hello = (hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening") + (name.map { ", \($0)" } ?? "") + "."
        var parts: [String] = []
        if let first = events.first {
            let more = events.count > 1 ? " and \(events.count - 1) more after" : ""
            parts.append("You have \(first.title)\(first.time.map { " at \(time.string(from: $0))" } ?? " today")\(more).")
        }
        if let first = reminders.first {
            parts.append(reminders.count == 1 ? "\(first.title) is due today." : "\(first.title) and \(reminders.count - 1) other reminders are due.")
        }
        if parts.isEmpty { parts.append("Nothing on your calendar today.") }
        return ([hello] + parts).joined(separator: " ")
    }
}
