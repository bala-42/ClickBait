import Foundation

/// The free, keyless places Internet Mode reads (no accounts, no paid services).
public enum WebSource: String, CaseIterable, Sendable {
    case searxng, wikipedia, stackOverflow, mdn, appleDocs

    public var displayName: String {
        switch self {
        case .searxng: "the web"
        case .wikipedia: "Wikipedia"
        case .stackOverflow: "Stack Overflow"
        case .mdn: "MDN"
        case .appleDocs: "Apple Developer"
        }
    }
}

/// A page's readable text, from one source.
public struct WebDocument: Equatable, Sendable {
    public var title: String
    public var url: URL
    public var text: String
    public var source: WebSource

    public init(title: String, url: URL, text: String, source: WebSource) {
        self.title = title
        self.url = url
        self.text = text
        self.source = source
    }
}

/// A piece of a document chosen for the answer.
public struct WebPassage: Equatable, Sendable {
    public var title: String
    public var url: URL
    public var text: String
    public var source: WebSource

    public init(title: String, url: URL, text: String, source: WebSource) {
        self.title = title
        self.url = url
        self.text = text
        self.source = source
    }
}

/// Which sources suit a question (spec decision 12): technical ones by their words,
/// Wikipedia for general questions, SearXNG first whenever it's running.
public enum WebSourcePicker {
    static let codeWords = #"\b(?:error|exception|traceback|python|javascript|typescript|java|kotlin|rust|golang|c\+\+|c#|ruby|php|node|npm|pip|git|bash|zsh|regex|sql|compile|compiler|null|undefined|segfault|stack\s+trace|docker)\b"#
    static let webWords = #"\b(?:javascript|typescript|css|html|dom|fetch|promise|async|await|addeventlistener|queryselector|websocket|localstorage|canvas|flexbox|svg|webgl|service\s+worker|web\s+api|browser\s+api)\b"#
    static let appleWords = #"\b(?:swift|swiftui|appkit|uikit|foundation|xcode|combine|urlsession|avfoundation|core\s*data|coreml|core\s+ml|metal|swiftdata|observation|nsview|uiview|nswindow|ios\s+sdk|macos\s+sdk)\b|\b(?:NS|UI|AV|CG|CA)[A-Z][A-Za-z]+\b"#

    public static func sources(question: String, query: String, reason: WebLookup.Reason?,
                               searxngAvailable: Bool) -> [WebSource] {
        let text = question + " " + query
        func has(_ pattern: String, caseSensitive: Bool = false) -> Bool {
            text.range(of: pattern, options: caseSensitive ? [.regularExpression] : [.regularExpression, .caseInsensitive]) != nil
        }
        var picked: [WebSource] = []
        if searxngAvailable { picked.append(.searxng) }
        // Recent facts (versions, releases, news) are encyclopaedia material, not Q&A threads.
        let recent = reason == .recent
        if reason == .error || (!recent && has(codeWords)) { picked.append(.stackOverflow) }
        if !recent, has(webWords) { picked.append(.mdn) }
        if !recent, AppleSymbol.guess(query) != nil || AppleSymbol.guess(question) != nil { picked.append(.appleDocs) }
        let technical = picked.contains { [.stackOverflow, .mdn, .appleDocs].contains($0) }
        if !technical || recent { picked.append(.wikipedia) }
        return picked
    }
}

/// Requests for each source (endpoints checked 2026-10-10; no keys anywhere).
public enum WebRequests {
    public static let userAgent = WikipediaClient.userAgent
    public static let searxngBase = URL(string: "http://127.0.0.1:8888")!

    static func url(_ base: String, _ items: [(String, String)]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components?.url
    }

    /// One request: the top 3 articles with their opening paragraphs and links.
    public static func wikipedia(_ query: String) -> URL? {
        url("https://en.wikipedia.org/w/api.php", [
            ("action", "query"), ("generator", "search"), ("gsrsearch", query), ("gsrlimit", "3"),
            ("prop", "extracts|info"), ("inprop", "url"), ("exintro", "1"), ("explaintext", "1"),
            ("exlimit", "3"), ("format", "json"),
        ])
    }

    public static func stackOverflowSearch(_ query: String) -> URL? {
        url("https://api.stackexchange.com/2.3/search/advanced", [
            ("order", "desc"), ("sort", "relevance"), ("accepted", "True"), ("site", "stackoverflow"),
            ("q", query), ("pagesize", "3"),
        ])
    }

    public static func stackOverflowAnswers(_ ids: [Int]) -> URL? {
        guard !ids.isEmpty else { return nil }
        return url("https://api.stackexchange.com/2.3/answers/\(ids.map(String.init).joined(separator: ";"))", [
            ("site", "stackoverflow"), ("filter", "withbody"), ("order", "desc"), ("sort", "votes"),
        ])
    }

    public static func mdnSearch(_ query: String) -> URL? {
        url("https://developer.mozilla.org/api/v1/search", [("q", query), ("locale", "en-US")])
    }

    public static func mdnPage(_ path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        return URL(string: "https://developer.mozilla.org\(path)/index.json")
    }

    /// Apple's documentation data for "<Framework> <Symbol>" ("SwiftUI List"), "URLSession",
    /// "NSWindow": the symbol's own page, or nil when the words don't name one.
    public static func appleDocs(_ query: String) -> (data: URL, page: URL)? {
        guard let (framework, symbol) = AppleSymbol.guess(query) else { return nil }
        let path = "\(framework)/\(symbol)".lowercased()
        guard let data = URL(string: "https://developer.apple.com/tutorials/data/documentation/\(path).json"),
              let page = URL(string: "https://developer.apple.com/documentation/\(path)") else { return nil }
        return (data, page)
    }

    public static func searxng(_ query: String) -> URL? {
        url(searxngBase.absoluteString + "/search", [("q", query), ("format", "json")])
    }
}

enum AppleSymbol {
    static let frameworks = ["swiftui", "appkit", "uikit", "foundation", "combine", "avfoundation", "coredata",
                             "coreml", "metal", "swiftdata", "observation", "mapkit", "eventkit", "vision",
                             "naturallanguage", "screencapturekit", "storekit", "widgetkit", "charts", "swift"]
    static let typeFramework: [(prefix: String, framework: String)] = [
        ("NS", "appkit"), ("UI", "uikit"), ("AV", "avfoundation"), ("URL", "foundation"), ("CG", "coregraphics"),
    ]

    static func guess(_ query: String) -> (String, String)? {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"()?")) }
        // "SwiftUI List", "Foundation URLSession".
        for (index, word) in words.enumerated() where frameworks.contains(word.lowercased()) && index + 1 < words.count {
            let next = words[index + 1].split(separator: ".").first.map(String.init) ?? ""
            if next.first?.isUppercase == true, next.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return (word.lowercased() == "swift" ? "swift" : word, next)
            }
        }
        // "NSWindow", "URLSession.data".
        for word in words {
            let type = word.split(separator: ".").first.map(String.init) ?? word
            for (prefix, framework) in typeFramework where type.hasPrefix(prefix) && type.count > prefix.count + 1 {
                let rest = type.dropFirst(prefix.count)
                if rest.first?.isUppercase == true, type.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    return (framework, type)
                }
            }
        }
        return nil
    }
}

/// Each source's reply → readable documents; anything malformed → [].
public enum WebParsers {
    static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public static func wikipedia(_ data: Data) -> [WebDocument] {
        guard let pages = (json(data)?["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        let sorted = pages.values.compactMap { $0 as? [String: Any] }
            .sorted { ($0["index"] as? Int ?? .max) < ($1["index"] as? Int ?? .max) }
        return sorted.compactMap { page in
            guard let title = page["title"] as? String,
                  let extract = (page["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !extract.isEmpty, !extract.contains("may refer to:"),
                  let url = (page["fullurl"] as? String).flatMap(URL.init(string:)) else { return nil }
            return WebDocument(title: title, url: url, text: extract, source: .wikipedia)
        }
    }

    /// Questions with an accepted answer: (question id, title, link, accepted answer id).
    public static func stackOverflowQuestions(_ data: Data) -> [(id: Int, title: String, link: URL, answer: Int)] {
        guard let items = json(data)?["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["question_id"] as? Int, let answer = item["accepted_answer_id"] as? Int,
                  let title = item["title"] as? String, let link = (item["link"] as? String).flatMap(URL.init(string:))
            else { return nil }
            return (id, HTMLText.decodeEntities(title), link, answer)
        }
    }

    /// Answer id → its body as readable text.
    public static func stackOverflowAnswers(_ data: Data) -> [Int: String] {
        guard let items = json(data)?["items"] as? [[String: Any]] else { return [:] }
        var bodies: [Int: String] = [:]
        for item in items {
            if let id = item["answer_id"] as? Int, let body = item["body"] as? String {
                bodies[id] = HTMLText.readable(body)
            }
        }
        return bodies
    }

    /// Search hits: (title, page path like "/en-US/docs/Web/API/Fetch_API", summary).
    public static func mdnSearch(_ data: Data) -> [(title: String, path: String, summary: String)] {
        guard let documents = json(data)?["documents"] as? [[String: Any]] else { return [] }
        return documents.compactMap { document in
            guard let title = document["title"] as? String, let path = document["mdn_url"] as? String else { return nil }
            return (title, path, document["summary"] as? String ?? "")
        }
    }

    public static func mdnPage(_ data: Data, page: URL) -> WebDocument? {
        guard let doc = json(data)?["doc"] as? [String: Any], let title = doc["title"] as? String,
              let body = doc["body"] as? [[String: Any]] else { return nil }
        let text = body.compactMap { section -> String? in
            guard section["type"] as? String == "prose", let value = section["value"] as? [String: Any],
                  let content = value["content"] as? String else { return nil }
            let heading = (value["title"] as? String).map { $0 + "\n" } ?? ""
            return heading + HTMLText.readable(content)
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return WebDocument(title: title, url: page, text: text, source: .mdn)
    }

    /// Apple's DocC JSON: the symbol's summary and its overview paragraphs.
    public static func appleDocs(_ data: Data, page: URL) -> WebDocument? {
        guard let object = json(data) else { return nil }
        let title = (object["metadata"] as? [String: Any])?["title"] as? String ?? page.lastPathComponent
        var paragraphs: [String] = []
        if let abstract = object["abstract"] as? [[String: Any]] { paragraphs.append(inline(abstract)) }
        for section in object["primaryContentSections"] as? [[String: Any]] ?? [] where section["kind"] as? String == "content" {
            for block in section["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "paragraph": paragraphs.append(inline(block["inlineContent"] as? [[String: Any]] ?? []))
                case "heading": (block["text"] as? String).map { paragraphs.append($0) }
                case "codeListing": (block["code"] as? [String]).map { paragraphs.append($0.joined(separator: "\n")) }
                default: break
                }
            }
        }
        let text = paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return WebDocument(title: title, url: page, text: text, source: .appleDocs)
    }

    static func inline(_ parts: [[String: Any]]) -> String {
        parts.compactMap { $0["text"] as? String ?? $0["code"] as? String }.joined()
    }

    /// Results: (title, address, snippet); addresses that aren't https are dropped.
    public static func searxng(_ data: Data) -> [(title: String, url: URL, snippet: String)] {
        guard let results = json(data)?["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result in
            guard let url = (result["url"] as? String).flatMap(URL.init(string:)), url.scheme == "https" else { return nil }
            return (result["title"] as? String ?? url.host ?? "", url, result["content"] as? String ?? "")
        }
    }
}

/// HTML → readable text: no scripts, styles or page furniture; entities decoded;
/// paragraphs kept as blank-line breaks.
public enum HTMLText {
    public static func readable(_ html: String) -> String {
        var text = html
        let dropped = ["script", "style", "noscript", "nav", "header", "footer", "aside", "form", "svg", "iframe", "template"]
        for tag in dropped {
            text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(?:p|div|li|h[1-6]|pre|tr|blockquote|section|article|dd|dt|title)\\s*>",
                                         with: "\n\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<li\\b[^>]*>", with: "• ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func title(in html: String) -> String? {
        guard let range = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let raw = html[range].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let title = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                                ("&apos;", "'"), ("&#x27;", "'"), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
                                ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result), let hexRange = Range(match.range(at: 1), in: result),
                      let digitsRange = Range(match.range(at: 2), in: result) else { continue }
                let radix = result[hexRange].isEmpty ? 10 : 16
                if let code = UInt32(result[digitsRange], radix: radix), let scalar = Unicode.Scalar(code) {
                    result.replaceSubrange(whole, with: String(Character(scalar)))
                }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Chooses the passages closest to the question within a budget, each source getting a
/// fair share (round robin, best first). ~4 characters a token.
public enum PassagePicker {
    public static let defaultBudget = 3_200  // ~800 tokens (spec decision 10)

    public static func pick(_ documents: [WebDocument], question: String, budget: Int = defaultBudget,
                            score: (String, String) -> Double = wordOverlap) -> [WebPassage] {
        var queues: [WebSource: [(score: Double, passage: WebPassage)]] = [:]
        var order: [WebSource] = []
        for document in documents {
            if queues[document.source] == nil { order.append(document.source); queues[document.source] = [] }
            for (index, chunk) in chunks(of: document.text).enumerated() {
                // Earlier paragraphs (an article's summary, an accepted answer's start) get a nudge.
                let value = score(question, chunk) + 0.05 / Double(index + 1)
                queues[document.source]?.append((value, WebPassage(title: document.title, url: document.url, text: chunk,
                                                                   source: document.source)))
            }
        }
        for source in order { queues[source]?.sort { $0.score > $1.score } }
        order.sort { (queues[$0]?.first?.score ?? 0) > (queues[$1]?.first?.score ?? 0) }

        var picked: [WebPassage] = []
        var used = 0
        var progress = true
        while progress {
            progress = false
            for source in order {
                guard var queue = queues[source] else { continue }
                while let next = queue.first {
                    queue.removeFirst()
                    if used + next.passage.text.count <= budget {
                        picked.append(next.passage)
                        used += next.passage.text.count
                        progress = true
                        break
                    }
                }
                queues[source] = queue
            }
        }
        return picked
    }

    /// Paragraphs merged up to ~600 characters; long ones cut at a sentence; tiny ones dropped.
    static func chunks(of text: String, target: Int = 600) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result: [String] = []
        var current = ""
        func flush() {
            if current.count >= 40 { result.append(current) }
            current = ""
        }
        for paragraph in paragraphs {
            var rest = Substring(paragraph)
            while rest.count > target {
                let window = rest.prefix(target)
                let cut = window.lastIndex(where: { $0 == "." || $0 == "\n" }).map { rest.index(after: $0) } ?? window.endIndex
                flush()
                current = String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                flush()
                rest = rest[cut...].drop(while: { $0.isWhitespace })
            }
            let piece = String(rest)
            if current.isEmpty { current = piece } else if current.count + piece.count + 2 <= target { current += "\n\n" + piece }
            else { flush(); current = piece }
        }
        flush()
        return result
    }

    static let stopWords: Set<String> = ["the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "how", "what",
                                         "why", "who", "when", "where", "which", "does", "this", "that", "with", "from",
                                         "have", "has", "was", "were", "will", "your", "its", "into", "about", "look", "up"]

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    /// Share of the question's words found in the passage (a fallback when no embedding).
    public static func wordOverlap(_ question: String, _ passage: String) -> Double {
        let asked = Set(words(question))
        guard !asked.isEmpty else { return 0 }
        let present = Set(words(passage))
        return Double(asked.intersection(present).count) / Double(asked.count)
    }
}
