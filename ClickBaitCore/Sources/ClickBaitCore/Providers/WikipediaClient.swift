import Foundation

/// An article's opening, as background for naming the parts of a snip.
public struct WikiReference: Equatable, Sendable {
    public var title: String
    public var extract: String
    public var url: URL

    public init(title: String, extract: String, url: URL) {
        self.title = title
        self.extract = extract
        self.url = url
    }

    /// Markdown credit for the chat: Wikipedia's text is CC BY-SA, so a quote is credited.
    public var credit: String { "Source: [Wikipedia — \(title)](\(url.absoluteString))" }
}

/// English Wikipedia: one search, then the top hit's summary. Only the subject words the
/// model named are sent (never the screen, its text or audio); free, no account or key.
/// Measured 2026-10-10: ~0.3 s cold, ~0.04 s warm; an intro is ~100–450 tokens.
public struct WikipediaClient: Sendable {
    /// Wikimedia asks API clients to name themselves and a way to reach them.
    public static let userAgent = "ClickBait/0.1 (https://github.com/bala-42/ClickBait)"
    /// Enough for a parts tour's background; a whole article is 1,000+ tokens.
    public static let maxExtractCharacters = 1_200
    static let timeout: TimeInterval = 3

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The best article for `subject`, or nil (nothing found, offline, slow, cancelled).
    public func reference(for subject: String) async -> WikiReference? {
        guard let searchURL = Self.searchURL(for: subject),
              let found = await get(searchURL).flatMap(Self.topTitle(inSearch:)),
              let summaryURL = Self.summaryURL(forTitle: found),
              let data = await get(summaryURL) else { return nil }
        return Self.reference(inSummary: data)
    }

    private func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static func searchURL(for subject: String) -> URL? {
        let terms = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { return nil }
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: terms),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "srprop", value: ""),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    static func summaryURL(forTitle title: String) -> URL? {
        let path = title.replacingOccurrences(of: " ", with: "_")
        guard let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) else {
            return nil
        }
        return URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(escaped)")
    }

    static func topTitle(inSearch data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = object["query"] as? [String: Any],
              let hits = query["search"] as? [[String: Any]],
              let title = hits.first?["title"] as? String, !title.isEmpty else { return nil }
        return title
    }

    /// A disambiguation page ("Mercury may refer to…") says nothing about the picture.
    static func reference(inSummary data: Data) -> WikiReference? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String != "disambiguation",
              let title = object["title"] as? String,
              let extract = (object["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !extract.isEmpty else { return nil }
        let urls = (object["content_urls"] as? [String: Any])?["desktop"] as? [String: Any]
        let fallback = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            .flatMap { URL(string: "https://en.wikipedia.org/wiki/" + $0) }
        guard let url = (urls?["page"] as? String).flatMap(URL.init(string:)) ?? fallback else { return nil }
        return WikiReference(title: title, extract: trimmed(extract), url: url)
    }

    static func trimmed(_ extract: String) -> String {
        guard extract.count > maxExtractCharacters else { return extract }
        let prefix = extract.prefix(maxExtractCharacters)
        let cut = prefix.lastIndex(where: { $0 == "." }).map { prefix[...$0] } ?? prefix
        return String(cut)
    }
}

/// The `"subject"` a snip reply opens with (`Prompt.system`), read while the reply streams,
/// so the lookup starts before the explanation is finished.
public enum StreamingSubject {
    /// The subject once its string has closed, or nil (not there yet, "none", or not a
    /// sensible search: empty, too long).
    public static func subject(in partial: String) -> String? {
        guard let key = partial.range(of: "\"subject\"") else { return nil }
        var rest = partial[key.upperBound...].drop(while: { $0 == " " || $0 == "\n" })
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\n" })
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()
        var value = ""
        var escaped = false
        for character in rest {
            if escaped { value.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { return searchable(value) }
            value.append(character)
        }
        return nil  // still streaming
    }

    static func searchable(_ value: String) -> String? {
        let subject = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = subject.split(whereSeparator: \.isWhitespace)
        guard !subject.isEmpty, subject.lowercased() != "none", words.count <= 6, subject.count <= 60 else { return nil }
        return subject
    }
}
