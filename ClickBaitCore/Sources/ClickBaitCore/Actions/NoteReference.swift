import Foundation

/// A note or reminder that's about something on screen ("add this page's URL to my
/// notes", "note the selected text"): its text must be that thing, not the words of
/// the order. The model copied the order into the note.
public enum NoteReference: Equatable, Sendable {
    case pageAddress
    case selection
    /// "Add it to my notes" in a chat: the last answer (or the selection, outside one).
    case previous

    public static func find(in order: String) -> NoteReference? {
        let text = " " + ImpliedPointer.normalized(order) + " "
        let selection = [" selected ", " selection ", " highlighted ", " this text ", " that text "]
        if selection.contains(where: text.contains) { return .selection }
        let page = [" url ", " urls ", " link ", " address ", " this page ", " this pages ", " this website ", " this site ",
                    " this tab ", " this webpage ", " the page "]
        if page.contains(where: text.contains) { return .pageAddress }
        // "Add it to my notes", "save that as a note", "jot this down" — but not "note that
        // the plumber comes Tuesday", where a sentence follows.
        let pronouns: Set<String> = ["it", "that", "this", "them", "those"]
        let sentence: Set<String> = ["the", "a", "an", "i", "we", "my", "our", "he", "she", "you", "they", "its", "there", "is", "was"]
        let words = text.split(separator: " ").map(String.init)
        for (position, word) in words.enumerated().prefix(4) where pronouns.contains(word) {
            let next = position + 1 < words.count ? words[position + 1] : ""
            if !sentence.contains(next) { return .previous }
        }
        return nil
    }

    /// What "add it" means from an answer: the link when there's exactly one ("The URL
    /// of this page is https://…"), otherwise the answer.
    public static func content(ofAnswer answer: String) -> String {
        let links = NoteHTML.links(in: answer)
        return links.count == 1 ? links[0] : answer
    }

    /// "Show me that note", "open the note", "where's the note?": after making one.
    public static func asksToSeeNote(_ order: String) -> Bool {
        let words = ImpliedPointer.normalized(order).split(separator: " ").map(String.init)
        guard words.contains(where: { $0 == "note" || $0 == "notes" }) || words == ["open", "it"] || words == ["show", "me", "it"] else { return false }
        let verbs: Set<String> = ["show", "open", "see", "view", "where", "wheres", "take", "go", "bring"]
        return words.prefix(3).contains(where: verbs.contains) && !words.contains("add") && !words.contains("make")
    }

    /// The note: the page's title above its address, or the selected text.
    public static func noteText(address: String, title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != address else { return address }
        return title + "\n" + address
    }
}

/// Reading a web address out of a browser's address bar.
public enum PageAddress {
    /// "https://github.com/x" or Chrome's shortened "github.com/x" → a full address;
    /// nil for search text or an empty bar ("how to cook rice").
    public static func fromAddressBar(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(" ") else { return nil }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return value }
        let host = value.split(separator: "/").first.map(String.init) ?? value
        guard host.contains("."), host.range(of: #"^[A-Za-z0-9.-]+(:\d+)?$"#, options: .regularExpression) != nil,
              let last = host.split(separator: ".").last, last.count >= 2, last.allSatisfy(\.isLetter) || host.hasPrefix("localhost")
        else { return nil }
        return "https://" + value
    }
}

/// Notes takes HTML for a note's body: each line its own paragraph (the first is the
/// note's title), links clickable.
public enum NoteHTML {
    public static func body(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var html = String(line).replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            for link in links(in: html) {
                html = html.replacingOccurrences(of: link, with: "<a href=\"\(link)\">\(link)</a>")
            }
            return "<div>\(html.isEmpty ? "<br>" : html)</div>"
        }.joined()
    }

    /// Web addresses in `text`, without trailing punctuation.
    public static func links(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]")) }
        }
    }
}
