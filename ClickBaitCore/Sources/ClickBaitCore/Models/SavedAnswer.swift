import Foundation

/// C5, saved answers (user's choice, 2026-10-20): the chat's question, answer and follow-ups as
/// a dated Markdown file the user keeps (`~/Library/Application Support/ClickBait/answers/`).
/// Text only: never screenshots or audio. Written only when the user presses Save.
///
///     SavedAnswer.fileName(question: "how do I zip a folder?", date: oct20)   // "2026-10-20 how do I zip a folder.md"
public enum SavedAnswer {
    public enum Role: Sendable { case user, assistant }

    /// "2026-10-20 how do I zip a folder.md": the date, then the first question (≤ 60
    /// characters, nothing a file name can't hold).
    public static func fileName(question: String, date: Date, calendar: Calendar = .current) -> String {
        let cleaned = question
            .map { "/:\\?%*|\"<>\n\r\t".contains($0) ? " " : $0 }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
        let title = cleaned.isEmpty ? "answer" : String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return "\(day(date, calendar: calendar)) \(title).md"
    }

    /// The file's text: a heading with the first question, the date, then each turn.
    public static func markdown(_ turns: [(role: Role, text: String)], date: Date, calendar: Calendar = .current) -> String {
        let first = turns.first { $0.role == .user }?.text ?? "Answer"
        var lines = ["# \(first)", "", "_Saved from ClickBait on \(day(date, calendar: calendar))._", ""]
        for turn in turns {
            switch turn.role {
            case .user: lines += ["**You:** \(turn.text)", ""]
            case .assistant: lines += [turn.text, ""]
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A name not taken yet: "… .md", then "… 2.md", "… 3.md".
    public static func unique(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let base = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        var number = 2
        while existing.contains("\(base) \(number).md") { number += 1 }
        return "\(base) \(number).md"
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
