import Foundation

/// Smart search (user's ask, 2026-11-01, after Taby): "find that note about the dentist",
/// "where's the march invoice", "show me the picture of the airport". Recognises a search
/// question, scores what was found by meaning (embeddings) and words, and writes the reply.
/// Everything it searches stays on this Mac.
public enum SmartSearch {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case any, file, image, video, note, reminder

        /// Pictures and videos: read and described by Vision Memory, shown as thumbnails.
        public var isVisual: Bool { self == .image || self == .video }

        public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"]
        public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp"]

        /// What a file is by its name: a picture, a video, else a file.
        public static func of(_ path: String) -> Kind {
            let ext = (path as NSString).pathExtension.lowercased()
            return imageExtensions.contains(ext) ? .image : videoExtensions.contains(ext) ? .video : .file
        }
    }

    public struct Request: Equatable, Sendable {
        public var kind: Kind
        /// The words that matter, lowercased, stop words and search words removed.
        public var terms: [String]
        /// What to embed: the question without its "find…" wrapper.
        public var text: String
        /// Words the brain says go with it ("dentist" → cleaning, appointment): nomic alone
        /// missed "cleaning on Tuesday" for "dentist" (`with(related:)`).
        public var related: [String] = []
        /// "a picture where I'm holding a dog": pictures with the user's face in them first
        /// (`Item.hasYou`, from the reference photo picked in Settings).
        public var wantsMe = false
        /// "the video I have open", "the pdf that's open", "what I'm watching": the files open in
        /// apps right now come first.
        public var openNow = false

        public init(kind: Kind, terms: [String], text: String, related: [String] = [], wantsMe: Bool = false) {
            self.kind = kind
            self.terms = terms
            self.text = text
            self.related = related
            self.wantsMe = wantsMe
        }

        /// The request with the brain's related words (comma-separated) added.
        public func with(related reply: String) -> Request {
            var copy = self
            copy.related = reply.lowercased().split { $0 == "," || $0 == "\n" }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
                .filter { $0.count > 2 && !terms.contains($0) }
                .prefix(8).map { $0 }
            if !copy.related.isEmpty { copy.text = text + ", " + copy.related.joined(separator: ", ") }
            return copy
        }

        /// What the brain is asked for the related words.
        public var relatedPrompt: String {
            "List 6 short words or phrases someone might have written in a note or file about: \(terms.joined(separator: " ")). Comma-separated, nothing else."
        }
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
        /// A file's size in bytes, for the card ("Downloads · Mar 12 · 4.2 MB").
        public var bytes: Int?
        /// Pictures: the brain's one line on what it shows ("a man hugging a white dog").
        public var caption: String?
        /// Pictures: the user's face is in it (matched to their reference photo).
        public var hasYou: Bool?
        /// Why it came up ("Matches “dog” in the picture"), set by `rank`.
        public var reason: String?
        /// Pictures: what identical copies share (size and a hash of the contents), so 17
        /// copies of one screenshot are read and described once and shown as one result.
        public var contentKey: String?
        /// The other copies' files, filled in by `VisionMemory.collapseCopies`.
        public var copies: [String]?
        /// Pictures whose text looked secret: that text isn't kept and the brain doesn't describe them.
        public var sensitive: Bool?
        /// The user wrote or corrected the caption: the brain never replaces it.
        public var userEdited: Bool?
        /// The brain that wrote the caption, so a new brain can describe again.
        public var captionModel: String?

        public init(id: String, kind: Kind, title: String, place: String, text: String, file: String? = nil, modified: Date? = nil,
                    bytes: Int? = nil, caption: String? = nil, hasYou: Bool? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.place = place
            self.text = text
            self.file = file
            self.modified = modified
            self.bytes = bytes
            self.caption = caption
            self.hasYou = hasYou
        }

        /// Everything searched: name, caption, the user tag, labels and text.
        public var searchable: String {
            [title, caption ?? "", hasYou == true ? "you, the user" : "", text].filter { !$0.isEmpty }.joined(separator: ". ")
        }

        /// The card's second line: folder, date, size.
        public func details(now: Date = Date(), calendar: Calendar = .current) -> String {
            var parts = [place]
            // The size second, so a narrow tile's one line still shows it (user's ask, 2026-11-02).
            if let bytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
            if let modified {
                let format = calendar.isDate(modified, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                parts.append(formatter.string(from: modified))
            }
            if let copies, !copies.isEmpty { parts.append("\(copies.count + 1) copies") }
            return parts.joined(separator: " · ")
        }
    }

    /// Words asking for videos (user's ask, 2026-11-01: "find shampoo videos" found nothing).
    static let videoWords: Set<String> = ["video", "videos", "clip", "clips", "movie", "movies", "recording", "recordings", "footage"]
    static let kindNouns: Set<String> = videoWords.union(["photos", "pictures", "pics", "images", "screenshots", "pdfs", "files",
                                                          "documents", "notes", "reminders"])
    /// Words saying it's open now. ("open" itself is also a stop word: "open the file" isn't a term.)
    static let openWords: Set<String> = ["open", "opened", "playing", "watching", "viewing", "showing", "current", "currently", "onscreen"]
    private static let uiWords: Set<String> = ["button", "menu", "icon", "tab", "toolbar", "setting", "settings", "field", "link",
                                               "checkbox", "switch", "option", "bar", "sidebar", "window"]
    private static let stopWords: Set<String> = ["the", "a", "an", "my", "me", "i", "that", "this", "about", "of", "for", "with", "from",
                                                 "on", "in", "to", "and", "or", "is", "was", "where", "wheres", "what", "did", "do", "have",
                                                 "find", "search", "look", "locate", "show", "write", "wrote", "save", "saved", "any",
                                                 "some", "there", "it", "called", "named", "which", "one", "please", "can", "you", "get",
                                                 "open", "file", "files", "document", "documents", "doc", "pdf", "pdfs", "note", "notes",
                                                 "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "screenshot",
                                                 "screenshots", "reminder", "reminders", "task", "tasks", "all", "had", "made", "took",
                                                 "taken", "got", "for", "up", "again", "earlier", "last", "recent",
                                                 "video", "videos", "clip", "clips", "movie", "movies", "recording", "recordings", "footage"]

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
        let kind: Kind = {
            if words.contains(where: Self.videoWords.contains) { return .video }
            if words.contains(where: ["photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "screenshot", "screenshots"].contains) { return .image }
            if words.contains(where: ["reminder", "reminders", "task", "tasks"].contains) { return .reminder }
            if words.contains(where: ["note", "notes", "wrote", "write"].contains) { return .note }
            if words.contains(where: ["file", "files", "pdf", "pdfs", "document", "documents", "doc", "invoice", "spreadsheet"].contains) { return .file }
            return .any
        }()
        // "Where's the march invoice pdf?" / "where is the picture of…": a named kind of thing.
        let whereThing = kind != .any && (words.first == "where" || words.first == "wheres")
        // A short phrase naming a kind of thing is a search too: "shampoo videos", "beach photos".
        let named = kind != .any && words.count <= 5 && Self.kindNouns.contains(words.last ?? "")
        guard asks.contains(where: { joined.contains($0) }) || words.first == "find" || words.first == "search" || whereThing || named
        else { return nil }
        let openNow = words.contains(where: Self.openWords.contains)
        let terms = words.filter { !stopWords.contains($0) && $0.count > 1 && !["im", "myself", "ive", "thats", "its", "whats"].contains($0) && !Self.openWords.contains($0) }
        guard !terms.isEmpty || (openNow && kind != .any) else { return nil }
        // "…where I'm holding a dog", "a photo of me": the user is in it ("show me", "find me"
        // and "I took" are just how it's asked).
        let selfWords = words.enumerated().filter { offset, word in
            switch word {
            case "im", "myself": return true
            case "me": return offset == 0 || !["show", "find", "give", "get", "send", "for"].contains(words[offset - 1])
            case "i": return offset + 1 < words.count && ["am", "was", "look", "looked"].contains(words[offset + 1])
            default: return false
            }
        }
        let wantsMe = kind == .image && !selfWords.isEmpty
        var request = Request(kind: kind, terms: terms, text: terms.isEmpty ? kind.rawValue : terms.joined(separator: " "), wantsMe: wantsMe)
        request.openNow = openNow
        return request
    }

    /// The word's stem for matching names: "shampooing" → "shampoo" (a file named
    /// "shampoo_input" never matched "shampooing"; user's report, 2026-11-02), "shoulders" →
    /// "shoulder", "wearing" → "wear". Short words are kept as they are.
    public static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// Share of the request's words found in the item's title and text (0…1).
    public static func wordMatch(_ request: Request, _ item: Item) -> Float {
        let haystack = item.searchable.lowercased()
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
            let haystack = entry.item.searchable.lowercased()
            let words = wordMatch(request, entry.item) + (request.related.contains(where: haystack.contains) ? 0.35 : 0)
            let you: Float = request.wantsMe ? (entry.item.hasYou == true ? 0.3 : -0.1) : 0
            let kindBonus: Float = request.kind == .any || request.kind == entry.item.kind ? 0.05 : -0.15
            // A name match says little about what a picture or video shows when it hasn't been
            // described yet: "girl shampooing her own hair" put ten undescribed "shampoo_input"
            // videos above the two described as a person washing their hair (2026-11-02).
            let nameOnly = entry.item.kind.isVisual && entry.item.caption == nil
            let spotlight: Float = boosted.contains(entry.item.id) ? (nameOnly ? 0.1 : 0.3) : 0
            return (entry.item, 0.7 * meaning + 0.3 * words + kindBonus + spotlight + you)
        }
        // Good on its own (0.4), or close to the best: "within 0.25 of the best" alone left one
        // result when a file Spotlight matched by name pulled far ahead (user's report:
        // "only generating one result when I clearly have more", 2026-11-01).
        let best = scored.map(\.1).max() ?? 0
        return scored
            .filter { $0.1 > 0.25 && ($0.1 >= 0.4 || $0.1 >= best - 0.25) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { entry in
                var item = entry.0
                item.reason = reason(for: item, request: request, spotlight: boosted.contains(item.id))
                return item
            }
    }

    /// Why a find came up, for the card: the words it holds and where, else meaning.
    public static func reason(for item: Item, request: Request, spotlight: Bool) -> String {
        let name = item.title.lowercased()
        let shown = ((item.caption ?? "") + " " + item.text).lowercased()
        let words = request.terms + request.related
        if request.wantsMe, item.hasYou == true {
            return words.first(where: shown.contains).map { "You, and “\($0)” in the picture" } ?? "You're in the picture"
        }
        if let word = words.first(where: name.contains) { return "Matches “\(word)” in the name" }
        if let word = words.first(where: shown.contains) {
            return "Matches “\(word)” " + (item.kind == .image ? "in the picture" : item.kind == .video ? "in the video" : item.kind == .file ? "inside" : "in the text")
        }
        if spotlight { return "Matches “\(request.terms.joined(separator: " "))” inside" }
        return "Close in meaning"
    }

    /// After a search: "open it", "open the second one", "show it in Finder".
    public enum FollowUp: Equatable, Sendable {
        case open(Int)
        case reveal(Int)
    }

    /// The follow-up and which result (0-based; "it" is the first), or nil.
    public static func followUp(in text: String, count: Int) -> FollowUp? {
        guard count > 0 else { return nil }
        let words = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty, words.count <= 8 else { return nil }
        let opening = words.contains("open") || (words.contains("show") && !words.contains("finder") && words.contains(where: ["it", "that", "one"].contains))
        let revealing = words.contains("finder") || words.contains("reveal") || (words.contains("show") && words.contains("folder"))
        guard opening || revealing else { return nil }
        let ordinals = ["first": 0, "1st": 0, "one": 0, "second": 1, "2nd": 1, "two": 1, "third": 2, "3rd": 2, "three": 2,
                        "fourth": 3, "4th": 3, "four": 3, "fifth": 4, "5th": 4, "five": 4]
        var index = 0
        if words.contains("last") { index = count - 1 }
        for (offset, word) in words.enumerated() {
            // "one" is a number only after "number" or before nothing else ("open the second one").
            if word == "one", offset > 0, ordinals[words[offset - 1]] != nil { continue }
            if word == "one", !words.contains("number") { continue }
            if let value = ordinals[word] ?? Int(word).map({ $0 - 1 }) { index = value; break }
        }
        // Only about the results: "it", "that", "this", an ordinal or "one" — not "open Safari".
        let pointsAtResult = words.contains(where: ["it", "that", "this", "one", "last", "them"].contains)
            || words.contains(where: { ordinals[$0] != nil || Int($0) != nil })
        guard pointsAtResult, index >= 0, index < count else { return nil }
        return revealing ? .reveal(index) : .open(index)
    }

    /// What the brain is asked for the spoken and written sentence about the best find.
    public static func sentencePrompt(_ found: [Item], question: String) -> String? {
        guard let top = found.first else { return nil }
        let what = top.kind == .image || top.kind == .video ? (top.caption ?? top.text) : top.text
        return """
        The user asked: "\(question)". The best match is a \(top.kind == .image ? "picture" : top.kind.rawValue) named         "\(top.title)" in \(top.place)\(what.isEmpty ? "" : ", showing or saying: \(what.prefix(200))")\(top.hasYou == true ? ", with the user in it" : "").\
        \(found.count > 1 ? " There are \(found.count) matches." : "")
        Write ONE short friendly sentence telling them what you found and where, then ask if they'd like you to open it.         Say "you" for the user. No file extensions, no lists.
        """
    }

    /// A line over the results card, also what's said aloud.
    /// `waiting`: pictures and videos found but not read yet; with none found, that's why.
    public static func headline(_ found: [Item], for request: Request, waiting: Int = 0, waitingWhy: String? = nil) -> String {
        switch found.count {
        case 0 where waiting > 0 && request.kind != .note && request.kind != .reminder && request.kind != .file:
            "I couldn't find it, but \(waiting) pictures and videos aren't read yet\(waitingWhy.map { " (\($0))" } ?? ""), so I can only match their names for now."
        case 0: "I couldn't find anything about \(request.text) on this Mac."
        case 1: "Found it."
        default: "Found \(found.count)."
        }
    }

    /// The full reply, kept in the chat's memory: what was found, each with where it is and a line of what it
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
