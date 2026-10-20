import Foundation

/// Dates the model can't know or count: today's date, and how many days until a day the
/// question names. A small local model guessed "30 days until Christmas" on 20 October (it
/// had no date, and counts badly), so ClickBait works it out and hands the model the fact.
///
///     DateFacts.lines(for: "how many days until christmas?", now: oct20)
///     // ["Today is Tuesday, 20 October 2026.",
///     //  "Christmas (Friday, 25 December 2026) is 66 days away, not counting today."]
public enum DateFacts {
    /// Named days: (month, day).
    static let holidays: [(names: [String], name: String, month: Int, day: Int)] = [
        (["christmas", "christmas day", "xmas"], "Christmas", 12, 25),
        (["christmas eve"], "Christmas Eve", 12, 24),
        (["new year", "new years", "new year s", "new years day", "new year s day"], "New Year's Day", 1, 1),
        (["new years eve", "new year s eve"], "New Year's Eve", 12, 31),
        (["halloween"], "Halloween", 10, 31),
        (["valentines day", "valentine s day", "valentines"], "Valentine's Day", 2, 14),
    ]
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                         "september", "october", "november", "december"]
    static let askOpeners = ["days until", "days till", "days to", "days left until", "days left till",
                             "days left to", "days left before", "days before", "long until", "long till"]

    /// Today's date; plus, when the question asks how long until a day it names, the count.
    public static func lines(for question: String, now: Date, calendar: Calendar = .current) -> [String] {
        var lines = ["Today is \(format(now, calendar: calendar))."]
        if let count = daysUntil(question, now: now, calendar: calendar) {
            let days = count.days == 1 ? "1 day" : "\(count.days) days"
            lines.append(count.days == 0
                ? "\(count.name) is today (\(format(count.date, calendar: calendar)))."
                : "\(count.name) (\(format(count.date, calendar: calendar))) is \(days) away, not counting today.")
        }
        return lines
    }

    /// "How many days until Christmas?" → Christmas, its next date, and the days to it (today
    /// not counted; 0 on the day). Nil when the question names no day.
    public static func daysUntil(_ question: String, now: Date, calendar: Calendar = .current) -> (name: String, date: Date, days: Int)? {
        let text = ImpliedPointer.normalized(question)
        guard let opener = askOpeners.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let rest = text[opener.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let (name, month, day) = target(in: String(rest)) else { return nil }
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: today)
        for candidateYear in [year, year + 1] {
            guard let date = calendar.date(from: DateComponents(year: candidateYear, month: month, day: day)),
                  date >= today,
                  let days = calendar.dateComponents([.day], from: today, to: date).day else { continue }
            return (name, date, days)
        }
        return nil
    }

    /// The day named at the start of `text`: a holiday, "december 25", "25 december",
    /// "december 25th".
    static func target(in text: String) -> (name: String, month: Int, day: Int)? {
        let trimmed = text.hasPrefix("the ") ? String(text.dropFirst(4)) : text
        // Longest names first: "christmas eve" before "christmas".
        let named = holidays.flatMap { holiday in holiday.names.map { ($0, holiday) } }.sorted { $0.0.count > $1.0.count }
        if let (_, holiday) = named.first(where: { trimmed == $0.0 || trimmed.hasPrefix($0.0 + " ") }) {
            return (holiday.name, holiday.month, holiday.day)
        }
        let words = trimmed.split(separator: " ").map(String.init)
        func dayNumber(_ word: String) -> Int? {
            let digits = word.prefix { $0.isNumber }
            guard let value = Int(digits), (1...31).contains(value),
                  ["", "st", "nd", "rd", "th"].contains(String(word.dropFirst(digits.count))) else { return nil }
            return value
        }
        guard words.count >= 2 else { return nil }
        if let month = months.firstIndex(of: words[0]), let day = dayNumber(words[1]) {
            return ("\(months[month].capitalized) \(day)", month + 1, day)
        }
        if let day = dayNumber(words[0]), let month = months.firstIndex(of: words[1]) {
            return ("\(months[month].capitalized) \(day)", month + 1, day)
        }
        return nil
    }

    static func format(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter.string(from: date)
    }
}
