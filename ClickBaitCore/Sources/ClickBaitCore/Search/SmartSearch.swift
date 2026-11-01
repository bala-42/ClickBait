import Foundation

/// Smart search (user's ask, 2026-11-01, after Taby): "find that note about the dentist",
/// "where's the march invoice", "show me the picture of the airport". Recognises a search
/// question, scores what was found by meaning (embeddings) and words, and writes the reply.
/// Everything it searches stays on this Mac.
public enum SmartSearch {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case any, file, image, note, reminder
    }

    public struct Request: Equatable, Sendable {
        public var kind: Kind
        /// The words that matter, lowercased, stop words and search words removed.
        public var terms: [String]
        /// What to embed: the question without its "find…" wrapper.
        public var text: String
    }

    /// One thing found: a file, a picture, a note, a reminder, a saved answer.
    public struct Item: Equatable, Sendable, Codable, Identifiable {
        public var id: String
        public var kind: Kind
        public var title: String
        /// Where it lives ("Downloads", "Notes", "Reminders · due Tue").
        public var place: String
        /// What it says or shows (a note's text, a picture's labels and words), searched and quoted.
        public var text: String
        /// A file to open, when there is one.
        public var file: String?
        public var modified: Date?

        public init(id: String, kind: Kind, title: String, place: String, text: String, file: String? = nil, modified: Date? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.place = place
            self.text = text
            self.file = file
            self.modified = modified
        }
    }

    private static let uiWords: Set<String> = ["button", "menu", "icon", "tab", "toolbar", "setting", "settings", "field", "link",
                                               "checkbox", "switch", "option", "bar", "sidebar", "window"]
    private static let stopWords: Set<String> = ["the", "a", "an", "my", "me", "i", "that", "this", "about", "of", "for", "with", "from",
                                                 "on", "in", "to", "and", "or", "is", "was", "where", "wheres", "what", "did", "do", "have",
                                                 "find", "search", "look", "locate", "show", "write", "wrote", "save", "saved", "any",
                                                 "some", "there", "it", "called", "named", "which", "one", "please", "can", "you", "get",
                                                 "open", "file", "files", "document", "documents", "doc", "pdf", "pdfs", "note", "notes",
                                                 "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "screenshot",
                                                 "screenshots", "reminder", "reminders", "task", "tasks", "all", "had", "made", "took",
                                                 "taken", "got", "for", "up", "again", "earlier", "last", "recent"]

    /// A search question, or nil. Asking for something on screen ("where's the share
    /// button?") is pointing, not search: UI words keep it out.
    public static func request(in question: String) -> Request? {
        let lower = question.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = lower.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map { $0.replacingOccurrences(of: "'", with: "") }
        guard !words.isEmpty, !words.contains(where: uiWords.contains) else { return nil }
        let joined = " " + words.joined(separator: " ") + " "
        let asks = ["find ", " search ", " look for ", " locate ", " where is my ", " wheres my ", " where is that ", " wheres that ",
                    " where did i put ", " what did i write ", " what did i save ", " what did i note ", " do i have a ", " do i have any ",
                    " show me my ", " show me the picture", " show me the photo", " show me the screenshot", " show me the pdf",
                    " show me the file", " show me that "]
        guard asks.contains(where: { joined.contains($0) }) || words.first == "find" || words.first == "search" else { return nil }
        let kind: Kind = {
            if words.contains(where: ["photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "screenshot", "screenshots"].contains) { return .image }
            if words.contains(where: ["reminder", "reminders", "task", "tasks"].contains) { return .reminder }
            if words.contains(where: ["note", "notes", "wrote", "write"].contains) { return .note }
            if words.contains(where: ["file", "files", "pdf", "pdfs", "document", "documents", "doc", "invoice", "spreadsheet"].contains) { return .file }
            return .any
        }()
        let terms = words.filter { !stopWords.contains($0) && $0.count > 1 }
        guard !terms.isEmpty else { return nil }
        return Request(kind: kind, terms: terms, text: terms.joined(separator: " "))
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// Share of the request's words found in the item's title and text (0…1).
    public static func wordMatch(_ request: Request, _ item: Item) -> Float {
        let haystack = (item.title + " " + item.text).lowercased()
        let hits = request.terms.filter { haystack.contains($0) }.count
        return Float(hits) / Float(max(1, request.terms.count))
    }

    /// Meaning first, words second, a nudge for the kind asked for; best first, weak ones out.
    /// `boosted`: ids Spotlight already matched by their contents.
    public static func rank(_ items: [(item: Item, vector: [Float]?)], for request: Request, query: [Float]?,
                            boosted: Set<String> = [], limit: Int = 5) -> [Item] {
        let scored = items.map { entry -> (Item, Float) in
            // nomic's similarities bunch up: unrelated ≈ 0.45, a match ≈ 0.6–0.7 (measured,
            // 2026-11-01); spread that band over 0…1.
            let similarity = query.flatMap { q in entry.vector.map { cosine(q, $0) } } ?? 0
            let meaning = min(1, max(0, (similarity - 0.5) / 0.25))
            let words = wordMatch(request, entry.item)
            let kindBonus: Float = request.kind == .any || request.kind == entry.item.kind ? 0.05 : -0.15
            let spotlight: Float = boosted.contains(entry.item.id) ? 0.3 : 0
            return (entry.item, 0.7 * meaning + 0.3 * words + kindBonus + spotlight)
        }
        let best = scored.map(\.1).max() ?? 0
        return scored
            .filter { $0.1 > 0.25 && $0.1 >= best - 0.25 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// The reply in the chat: what was found, each with where it is and a line of what it
    /// says; files and pictures as links that open them.
    public static func reply(_ found: [Item], for request: Request) -> String {
        guard !found.isEmpty else {
            return "I couldn't find anything about \(request.text) on this Mac."
        }
        var lines = [found.count == 1 ? "Found it:" : "Found \(found.count):"]
        for item in found {
            let title = item.file.map { "[\(item.title)](\(URL(fileURLWithPath: $0).absoluteString))" } ?? "**\(item.title)**"
            let snippet = item.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let quote = snippet.isEmpty ? "" : " · " + String(snippet.prefix(110)) + (snippet.count > 110 ? "…" : "")
            lines.append("• \(title) — \(item.place)\(quote)")
        }
        return lines.joined(separator: "\n")
    }
}
