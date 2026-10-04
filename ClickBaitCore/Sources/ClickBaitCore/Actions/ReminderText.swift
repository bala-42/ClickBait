import Foundation

/// The day a reminder is due, as said: "tomorrow", "Friday", "in 3 days", "the 12th".
public enum ReminderDay: Equatable, Sendable {
    /// Days from today: today 0, tomorrow 1, "in 3 days", "next week" 7.
    case inDays(Int)
    /// The coming one (today counts only as "today"), Calendar numbering: 1 = Sunday.
    case weekday(Int)
    /// This month, or next month once it has passed.
    case dayOfMonth(Int)

    /// The all-day due date (year, month, day — no hour, so no alert at an odd time).
    public func dueDate(from now: Date, calendar: Calendar = .current) -> DateComponents {
        let today = calendar.startOfDay(for: now)
        let date: Date
        switch self {
        case .inDays(let days):
            date = calendar.date(byAdding: .day, value: days, to: today) ?? today
        case .weekday(let weekday):
            let ahead = (weekday - calendar.component(.weekday, from: today) + 7) % 7
            date = calendar.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: today) ?? today
        case .dayOfMonth(let day):
            var parts = calendar.dateComponents([.year, .month], from: today)
            parts.day = day
            var found: Date?
            // This month if that day is still to come, else the next month that has it.
            for _ in 0..<13 {
                if let candidate = calendar.date(from: parts),
                   calendar.component(.day, from: candidate) == day, candidate >= today {
                    found = candidate
                    break
                }
                parts.month = (parts.month ?? 1) + 1
            }
            date = found ?? today
        }
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    /// Words `ReminderText.parse` reads back as this day, to add to a reminder's text
    /// once the user has answered "when?".
    public var phrase: String {
        switch self {
        case .inDays(0): "today"
        case .inDays(1): "tomorrow"
        case .inDays(let days): "in \(days) days"
        case .weekday(let weekday):
            "on " + (Self.weekdays.first { $0.value == weekday }?.key ?? "monday")
        case .dayOfMonth(let day): "on the \(day)\(Self.ordinalSuffix(day))"
        }
    }

    private static func ordinalSuffix(_ day: Int) -> String {
        if (11...13).contains(day % 100) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// The day on its own ("Friday.", "on the 12th", "tomorrow please"), as a spoken
    /// answer to "when?". Nil if it isn't one.
    public static func parse(_ text: String) -> ReminderDay? {
        var words = ReminderText.words(text)
        while let last = words.last, ["please", "thanks", "thank", "you"].contains(last) { words.removeLast() }
        while let first = words.first, ["um", "uh", "oh", "make", "it", "do", "for", "on", "by", "set", "due"].contains(first) {
            words.removeFirst()
        }
        return phrase(words)
    }

    /// A whole phrase that names a day, e.g. ["next", "friday"], or nil.
    static func phrase(_ words: [String]) -> ReminderDay? {
        var words = words
        let hasLeadIn = ["on", "by", "for", "the"].contains(words.first ?? "")
        if let first = words.first, ["on", "by", "for", "this", "next", "coming", "the"].contains(first), words.count > 1 {
            // "next week" is a week away; "next Friday" is the coming Friday.
            if words == ["next", "week"] { return .inDays(7) }
            words.removeFirst()
            if let again = words.first, ["the", "this", "next", "coming"].contains(again), words.count > 1 { words.removeFirst() }
        }
        switch words {
        case ["today"], ["tonight"], ["this", "evening"], ["this", "afternoon"], ["this", "morning"], ["later"], ["later", "today"]:
            return .inDays(0)
        case ["tomorrow"], ["tomorrow", "morning"], ["tomorrow", "evening"], ["tomorrow", "night"]:
            return .inDays(1)
        case ["day", "after", "tomorrow"], ["the", "day", "after", "tomorrow"]:
            return .inDays(2)
        case ["next", "week"], ["week"]:
            return .inDays(7)
        default:
            break
        }
        if words.count == 1, let weekday = weekdays[words[0]] { return .weekday(weekday) }
        // "in 3 days", "in three days", "in a week", "in 2 weeks".
        if words.count == 3, words[0] == "in", let count = number(words[1]) {
            switch words[2] {
            case "day", "days": return .inDays(count)
            case "week", "weeks": return .inDays(count * 7)
            default: return nil
            }
        }
        // "the 12th", "12th", "on 12" — a bare "12" alone is a count ("buy eggs 12"), not a date.
        if words.count == 1, let day = dayOfMonth(words[0], bareNumberAllowed: hasLeadIn) { return .dayOfMonth(day) }
        return nil
    }

    static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static func number(_ word: String) -> Int? {
        let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                     "eight": 8, "nine": 9, "ten": 10]
        if let value = words[word] { return value }
        guard let value = Int(word), (1...365).contains(value) else { return nil }
        return value
    }

    private static func dayOfMonth(_ word: String, bareNumberAllowed: Bool) -> Int? {
        var digits = word
        for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) { digits.removeLast(2) }
        guard digits != word || bareNumberAllowed, let day = Int(digits), (1...31).contains(day) else { return nil }
        return day
    }
}

/// Turns what was said after "remind me" into a reminder: its title, in small letters,
/// and the day it's due, if one was said ("…tomorrow", "by Friday", "on the 12th").
/// No day → nil, and ClickBait asks: an undated reminder never shows in the Today
/// widget most people keep.
public enum ReminderText {
    public static func parse(_ text: String) -> (title: String, day: ReminderDay?) {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = original.split(whereSeparator: \.isWhitespace).map(String.init)
        var day: ReminderDay?
        // The longest day phrase at the end ("…by next Friday"), else at the start.
        for length in stride(from: min(4, words.count - 1), through: 1, by: -1) where day == nil {
            let tail = Self.words(words.suffix(length).joined(separator: " "))
            if let found = ReminderDay.phrase(tail) {
                day = found
                words.removeLast(length)
                while let last = words.last, ["on", "by", "for", "due"].contains(Self.words(last).first ?? "") {
                    words.removeLast()
                }
            }
        }
        for length in stride(from: min(4, words.count - 1), through: 1, by: -1) where day == nil {
            let head = Self.words(words.prefix(length).joined(separator: " "))
            if let found = ReminderDay.phrase(head) {
                day = found
                words.removeFirst(length)
            }
        }
        var title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!-"))
        if title.isEmpty { title = original }
        // Small letters, as the user keeps their reminders — but never a web address.
        if !title.contains("://") { title = title.lowercased() }
        return (title, day)
    }

    /// Lowercased words without punctuation ("Friday." → "friday"), keeping "12th".
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
