import Foundation

/// A note or reminder that's about something on screen ("add this page's URL to my
/// notes", "note the selected text"): its text must be that thing, not the words of
/// the order. The model copied the order into the note.
public enum NoteReference: Equatable, Sendable {
    case pageAddress
    case selection

    public static func find(in order: String) -> NoteReference? {
        let text = " " + ImpliedPointer.normalized(order) + " "
        let selection = [" selected ", " selection ", " highlighted ", " this text ", " that text "]
        if selection.contains(where: text.contains) { return .selection }
        let page = [" url ", " urls ", " link ", " address ", " this page ", " this pages ", " this website ", " this site ",
                    " this tab ", " this webpage ", " the page "]
        if page.contains(where: text.contains) { return .pageAddress }
        return nil
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
