import Foundation

/// When Internet Mode may go online for a question: fixed rules on the user's own words,
/// never the model's say (spec decision 3, 2026-10-10).
public enum WebLookup {
    public enum Reason: String, Sendable, Equatable {
        /// "look it up", "search the web", "google it" — the only reason the 🔒 note answers.
        case asked
        /// Something recent the local model can't know ("latest", "this week", "2026").
        case recent
        /// An error message ("this error", a traceback).
        case error
        /// An API or documentation question.
        case docs
    }

    /// Why this question should be looked up, or nil to answer locally.
    public static func reason(for question: String, selectedText: String? = nil) -> Reason? {
        let text = normalized(question)
        guard !text.isEmpty else { return nil }
        if explicitlyAsks(text) { return .asked }
        if matches(text, notAboutTheClock) { return nil }
        if matches(text, recentWords) { return .recent }
        if matches(text, errorWords) || (asksAbout(text) && looksLikeAnError(selectedText ?? "")) { return .error }
        if matches(text, docsWords) || matches(question, codeSymbol) { return .docs }
        return nil
    }

    public static func explicitlyAsks(_ question: String) -> Bool {
        matches(normalized(question), explicitPhrases)
    }

    /// The question points at something on screen ("look this error up", "what's this?"),
    /// so the search words have to come from the screen (via the local model).
    public static func refersToScreen(_ question: String) -> Bool {
        matches(normalized(question), screenWords)
    }

    /// The question without its trigger and filler words: the fallback search when the
    /// model's query step gives nothing. At most 12 words.
    public static func directQuery(_ question: String) -> String {
        var text = normalized(question)
        for pattern in strippedPhrases {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(QueryScrubber.maxWords)
        return words.joined(separator: " ")
    }

    /// The search words from step one's reply (`{"query": "..."}`), or nil.
    public static func query(inReply reply: String) -> String? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let query = (object["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else { return nil }
        return query
    }

    // MARK: - Rules

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[?!.,;:\"“”]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static let explicitPhrases = #"\blook\s+(?:(?:it|that|this|them|these|those)(?:\s+[a-z']+){0,3}\s+)?up\b(?!\s+(?:at|to)\b)|\bsearch\s+(?:the\s+)?(?:web|internet|online)\b|\bsearch\b.{1,60}\b(?:online|on\s+the\s+(?:web|internet))\b|\bgoogle\s+(?:it|that|this)\b|^google\b|\bcheck\s+(?:it\s+|that\s+)?(?:online|the\s+(?:web|internet))\b|\bfind\s+(?:it\s+|that\s+|this\s+)?online\b|\bwhat'?s\s+the\s+latest\s+on\b|\b(?:check|on)\s+wikipedia\b"#

    static let recentWords = #"\b(?:latest|newest|most\s+recent|current|currently|recent|recently|nowadays|up\s+to\s+date|this\s+(?:week|month|year)|last\s+(?:week|month)|right\s+now|news|released|release\s+date|came\s+out|just\s+(?:released|announced)|20[2-9]\d)\b"#

    /// "what's the current time / today's date": the Mac knows, no lookup.
    static let notAboutTheClock = #"\b(?:what\s+time|current\s+time|time\s+is\s+it|today'?s\s+date|what\s+day\s+is|date\s+today)\b"#

    static let errorWords = #"\b(?:error|errors|exception|traceback|stack\s+trace|segfault|crash(?:es|ed|ing)?|fails?\s+with|failed\s+with|warning)\b"#

    static let docsWords = #"\b(?:api|apis|function|method|methods|struct|protocol|parameter|parameters|argument|signature|framework|library|package|module|docs|documentation|syntax|deprecated)\b"#

    /// `URLSession.data`, `fetch()`, `useEffect(`: code in the user's words.
    static let codeSymbol = #"\b[A-Za-z_][A-Za-z0-9_]*\.[a-z][A-Za-z0-9_]+\b|\b[A-Za-z_][A-Za-z0-9_]*\(\)"#

    static let screenWords = #"\b(?:this|that|these|those|here|above|below|highlighted|selected|on\s+(?:my|the)\s+screen|look\s+it\s+up|google\s+it|search\s+it)\b"#

    static func asksAbout(_ text: String) -> Bool {
        matches(text, #"\b(?:what|why|how|fix|mean|means|meaning|explain|help)\b"#)
    }

    static func looksLikeAnError(_ text: String) -> Bool {
        text.range(of: #"\b(?:Error|Exception|Traceback|FATAL|fatal|panic|errno)\b"#, options: .regularExpression) != nil
    }

    static let strippedPhrases = [
        #"\b(?:hey\s+clickbait|clickbait|can\s+you|could\s+you|would\s+you|please|for\s+me|quickly|real\s+quick)\b"#,
        #"\blook\s+(?:it|that|this|them|these|those)\s+up\b|\blook\s+up\b|\bsearch\s+(?:the\s+)?(?:web|internet|online)\s*(?:for)?\b"#,
        #"\bon\s+the\s+(?:web|internet)\b|\bonline\b|\bgoogle\s+(?:it|that|this)\b|^google\b|\bcheck\s+wikipedia\b|\bon\s+wikipedia\b"#,
        #"\bwhat'?s\s+the\s+latest\s+on\b"#,
    ]
}

/// Takes personal details out of a search phrase before it leaves the Mac (spec decisions
/// 4–5): addresses, paths, long numbers, key-like strings, and names found on screen that
/// the user didn't say themselves. Then caps it at 12 words / 100 characters.
public enum QueryScrubber {
    public static let maxWords = 12
    public static let maxCharacters = 100

    static let patterns = [
        #"https?://\S+|\bwww\.\S+"#,                                        // web addresses
        #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#,              // email addresses
        #"(?:~|/Users|/home|/private|/var|/Volumes)(?:/\S*)?|\b[A-Za-z]:\\\S*|\S*/\S*/\S*"#,  // paths
        #"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{8,}|\b(?:ghp|gho|ghs|github_pat|xox[bpas])_?-?[A-Za-z0-9_-]{8,}|\bAKIA[A-Z0-9]{12,}"#,  // keys
        #"\b(?=[A-Za-z0-9_-]{20,}\b)(?=\S*[A-Za-z])(?=\S*\d)[A-Za-z0-9_-]+\b"#,  // long random-looking tokens
        #"\b\d[\d -]{3,}\d\b"#,                                              // long numbers (5+ digits)
    ]

    /// `screenNames`: people's names found on screen; removed unless `userWords` says them.
    public static func clean(_ phrase: String, screenNames: [String] = [], userWords: String = "") -> String {
        var text = phrase
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let said = userWords.lowercased()
        for name in screenNames where !name.isEmpty {
            for part in name.split(separator: " ").map(String.init) where part.count > 1 && !said.contains(part.lowercased()) {
                let escaped = NSRegularExpression.escapedPattern(for: part)
                text = text.replacingOccurrences(of: "\\b\(escaped)\\b", with: " ", options: [.regularExpression, .caseInsensitive])
            }
        }
        let words = text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’()[]{}<>,;:")) }
            .filter { !$0.isEmpty && $0.rangeOfCharacter(from: .alphanumerics) != nil }
            .prefix(maxWords)
        var result = ""
        for word in words {
            let next = result.isEmpty ? word : result + " " + word
            guard next.count <= maxCharacters else { break }
            result = next
        }
        return result
    }
}

/// Which page addresses a lookup may read (spec "Addresses"): HTTPS, and only ones seen in
/// the user's words, on screen, or in this lookup's results; plain HTTP only for the
/// SearXNG on this Mac.
public enum URLGuard {
    public static func allows(_ url: URL, seenIn seen: Set<URL>) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https": return seen.contains(where: { same($0, url) })
        case "http": return host == "localhost" || host == "127.0.0.1"
        default: return false
        }
    }

    /// Addresses in some text (the user's words, the screen's words, a page address).
    public static func addresses(in text: String) -> Set<URL> {
        guard let regex = try? NSRegularExpression(pattern: #"https://[^\s<>"'()\[\]]+"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let found = regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { URL(string: String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))) }
        }
        return Set(found)
    }

    static func same(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            var text = components?.string ?? url.absoluteString
            if text.hasSuffix("/") { text.removeLast() }
            return text.lowercased()
        }
        return key(a) == key(b)
    }
}
