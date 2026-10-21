import Foundation

/// C5, remembered facts (user's choice, 2026-10-20): short lines the user asked ClickBait to
/// keep ("remember my team is Atlas"), in a plain file they can edit
/// (`~/Library/Application Support/ClickBait/NOTES.md`, one `- YYYY-MM-DD: fact` per line).
/// Nothing is learned silently: only the user's words, a Services menu pick, or a card's
/// Remember button add a line, and the user sees it first. A newer fact about the same thing
/// replaces the older one; secrets are refused; at most `capacity` lines.
///
///     var memory = Memory(file: "")
///     memory.add("My team is Atlas", on: today)       // .saved("My team is Atlas")
///     memory.add("My team is Orion", on: today)       // replaces Atlas
///     memory.forget("my team")                        // removes it
///     memory.relevant(to: "who's on my team?")        // ["My team is Orion"] (before the forget)
public struct Memory: Equatable, Sendable {
    public struct Note: Equatable, Sendable {
        public var date: String
        public var text: String
    }

    public enum Outcome: Equatable, Sendable {
        case saved(String)
        case refusedSecret
        case empty
    }

    /// What the user's words ask for: "remember …", "forget …".
    public enum Command: Equatable, Sendable {
        case remember(String)
        case forget(String)
    }

    public static let capacity = 30
    /// What goes into a prompt: matching lines first, then the newest, up to this many characters.
    public static let promptBudget = 600

    public private(set) var notes: [Note]

    /// Reads the file's `- date: fact` lines; anything else in it (a heading, blank lines) is ignored.
    public init(file: String) {
        notes = file.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            let body = trimmed.dropFirst(2)
            guard let colon = body.firstIndex(of: ":") else { return nil }
            let date = body[..<colon].trimmingCharacters(in: .whitespaces)
            let text = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard date.count == 10, date.allSatisfy({ $0.isNumber || $0 == "-" }), !text.isEmpty else { return nil }
            return Note(date: date, text: text)
        }
    }

    /// The file to write back.
    public var file: String {
        (["# What ClickBait remembers", "", "One fact per line; edit or delete freely. Newest wins.", ""]
            + notes.map { "- \($0.date): \($0.text)" }).joined(separator: "\n") + "\n"
    }

    // MARK: Changing

    @discardableResult
    public mutating func add(_ fact: String, on date: Date, calendar: Calendar = .current) -> Outcome {
        let text = Self.tidy(fact)
        guard !text.isEmpty else { return .empty }
        guard !Self.looksSecret(text) else { return .refusedSecret }
        let key = Self.subject(of: text)
        notes.removeAll { $0.text.caseInsensitiveCompare(text) == .orderedSame || (key != nil && Self.subject(of: $0.text) == key) }
        notes.append(Note(date: Self.day(date, calendar: calendar), text: text))
        if notes.count > Self.capacity { notes.removeFirst(notes.count - Self.capacity) }
        return .saved(text)
    }

    /// Removes the lines about `thing` ("my team", "that I use Chrome"); returns how many went.
    @discardableResult
    public mutating func forget(_ thing: String) -> Int {
        let wanted = ImpliedPointer.normalized(Self.tidy(thing))
        guard !wanted.isEmpty else { return 0 }
        let before = notes.count
        notes.removeAll { note in
            let text = ImpliedPointer.normalized(note.text)
            return text.contains(wanted) || Self.subject(of: note.text).map { wanted.contains($0) || $0.contains(wanted) } == true
        }
        return before - notes.count
    }

    // MARK: Reading

    /// The lines for a question: those sharing a word with it first, then the newest, within
    /// `promptBudget` characters (a few hundredths of a second for the model).
    public func relevant(to question: String) -> [String] {
        let words = Self.contentWords(question)
        let matching = notes.reversed().filter { !Self.contentWords($0.text).isDisjoint(with: words) }
        let rest = notes.reversed().filter { note in !matching.contains(note) }
        var picked: [String] = []
        var used = 0
        for note in matching + rest {
            guard used + note.text.count <= Self.promptBudget else { continue }
            picked.append(note.text)
            used += note.text.count
        }
        return picked
    }

    /// The prompt block, or nil when there's nothing to say.
    public func block(for question: String) -> String? {
        let lines = relevant(to: question)
        guard !lines.isEmpty else { return nil }
        return (["What the user asked ClickBait to remember (their own facts; use them when they fit):"]
            + lines.map { "- \($0)" }).joined(separator: "\n")
    }

    // MARK: The user's words

    static let rememberLeads = ["please remember that", "please remember", "remember that", "remember", "don t forget that",
                                "don t forget", "dont forget that", "dont forget", "keep in mind that", "keep in mind",
                                "from now on", "note that"]
    static let forgetLeads = ["please forget that", "please forget", "forget that", "forget about", "forget"]

    /// "remember my team is Atlas" → .remember("my team is Atlas"); "forget my team" →
    /// .forget("my team"). Only at the start: "do you remember …" is a question, not an order.
    public static func command(in text: String) -> Command? {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = ImpliedPointer.normalized(spoken)
        guard !lower.hasPrefix("do you"), !lower.hasPrefix("can you remember"), !lower.hasSuffix(" remember") else { return nil }
        for lead in forgetLeads where lower.hasPrefix(lead + " ") {
            return .forget(rest(of: spoken, after: lead))
        }
        for lead in rememberLeads where lower.hasPrefix(lead + " ") {
            var fact = rest(of: spoken, after: lead)
            if lead == "note that" { guard fact.lowercased().hasPrefix("i ") || fact.lowercased().hasPrefix("my ") else { return nil } }
            if lead == "from now on", let first = fact.first { fact = "From now on, " + first.lowercased() + fact.dropFirst() }
            return .remember(fact)
        }
        return nil
    }

    /// The text after the lead's words, case kept ("Remember: My team is Atlas!" → "My team is
    /// Atlas"). The lead is counted in normalized words ("don't" is two: "don t").
    static func rest(of text: String, after lead: String) -> String {
        var toSkip = lead.split(separator: " ").count
        var index = text.startIndex
        while toSkip > 0, index < text.endIndex {
            while index < text.endIndex, !(text[index].isLetter || text[index].isNumber) { index = text.index(after: index) }
            while index < text.endIndex, text[index].isLetter || text[index].isNumber { index = text.index(after: index) }
            toSkip -= 1
        }
        return tidy(String(text[index...]))
    }

    // MARK: Rules

    /// Without lead-in punctuation and the end's full stop; a capital first letter.
    static func tidy(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;-–—")))
        while let last = trimmed.last, ".!".contains(last) { trimmed.removeLast() }
        guard let first = trimmed.first else { return "" }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// What a fact is about, so a newer one replaces it: the words before "is/are/use/…"
    /// ("my team is Atlas" → "my team"; "I use Chrome" → "i use"), or nil.
    static func subject(of text: String) -> String? {
        let words = ImpliedPointer.normalized(text).split(separator: " ").map(String.init)
        let verbs: Set<String> = ["is", "are", "was", "use", "uses", "prefer", "prefers", "live", "lives", "work", "works"]
        guard let index = words.firstIndex(where: { verbs.contains($0) }), index <= 4 else { return nil }
        let head = words[..<index].joined(separator: " ")
        // "I use" keeps the verb: "I use Chrome" and "I use Safari now" are one fact.
        return ["i", "we"].contains(head) ? head + " " + words[index] : (head.isEmpty ? nil : head)
    }

    /// Passwords, PINs, keys, tokens, card numbers: never written down.
    static func looksSecret(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = ["password", "passcode", "passwd", "pin code", "my pin", "api key", "secret key", "private key",
                     "token", "cvv", "security code", "seed phrase", "recovery phrase", "social security",
                     "passport number", "nric", "iban", "bank account", "account number", "routing number"]
        if words.contains(where: lower.contains) { return true }
        if PersonalData.contains(text) { return true }  // ID numbers: SSN, NRIC, passport, IBAN
        let digits = text.filter(\.isNumber)
        if digits.count >= 13, digits.count <= 19, text.range(of: #"(\d[ -]?){13,19}"#, options: .regularExpression) != nil { return true }
        // Long random-looking strings (keys): 24+ letters and digits mixed, no spaces.
        return text.split(separator: " ").contains { token in
            token.count >= 24 && token.contains(where: \.isNumber) && token.contains(where: \.isLetter)
                && token.allSatisfy { $0.isLetter || $0.isNumber || "-_=+/".contains($0) }
        }
    }

    static let stopWords: Set<String> = ["the", "and", "that", "this", "with", "what", "when", "where", "which", "about",
                                         "from", "have", "your", "mine", "they", "them", "there", "will", "would", "should",
                                         "could", "into", "does", "just", "like", "want", "need", "please"]

    static func contentWords(_ text: String) -> Set<String> {
        Set(ImpliedPointer.normalized(text).split(separator: " ").map(String.init).filter { $0.count >= 4 && !stopWords.contains($0) })
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
