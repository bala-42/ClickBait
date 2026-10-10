import Foundation

/// Runs one lookup's fixed steps against the chosen sources at once, within a deadline
/// (spec decision 9): 3 s per request, ~4 s in all, whatever has arrived is used.
/// One ephemeral session: no cookies, no cache, no credentials. Only search words and page
/// addresses are ever sent.
public actor WebFetcher {
    public struct Outcome: Sendable {
        public var documents: [WebDocument] = []
        /// Sources that answered with something, and ones that failed or ran out of time.
        public var answered: [WebSource] = []
        public var failed: [WebSource] = []
        public var timings: [WebSource: Duration] = [:]
    }

    public static let requestTimeout: TimeInterval = 3
    public static let deadline: Duration = .seconds(4)
    static let maxPageBytes = 2 * 1024 * 1024
    /// Stack Exchange allows 300 keyless requests a day from one address.
    static let stackExchangeDailyLimit = 290

    private let session: URLSession
    private var stackExchangeDay = ""
    private var stackExchangeCount = 0

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.httpAdditionalHeaders = ["User-Agent": WebRequests.userAgent]
            self.session = URLSession(configuration: configuration)
        }
    }

    /// `pages`: addresses from the user's words or the screen, already allowed by `URLGuard`.
    public func lookUp(query: String, sources: [WebSource], pages: [URL] = [],
                       deadline: Duration = WebFetcher.deadline) async -> Outcome {
        let allowStackExchange = takeStackExchangeRequests(2)
        let session = self.session
        var outcome = Outcome()
        let asked = sources.filter { $0 != .stackOverflow || allowStackExchange }
        await withTaskGroup(of: (WebSource?, [WebDocument], Duration).self) { group in
            for source in asked {
                group.addTask {
                    let start = ContinuousClock.now
                    let documents = await Self.fetch(source, query: query, session: session)
                    return (source, documents, ContinuousClock.now - start)
                }
            }
            for page in pages {
                group.addTask {
                    let start = ContinuousClock.now
                    let document = await Self.page(page, source: .searxng, session: session)
                    return (nil, document.map { [$0] } ?? [], ContinuousClock.now - start)
                }
            }
            // The deadline: a nil result that ends the wait.
            group.addTask {
                try? await Task.sleep(for: deadline)
                return (nil, [], .seconds(-1))
            }
            var waiting = Set(asked)
            var remaining = asked.count + pages.count
            while remaining > 0, let (source, documents, took) = await group.next() {
                if took == .seconds(-1) { break }
                remaining -= 1
                if let source {
                    waiting.remove(source)
                    outcome.timings[source] = took
                    if documents.isEmpty { outcome.failed.append(source) } else { outcome.answered.append(source) }
                }
                outcome.documents += documents
            }
            outcome.failed += waiting.sorted { $0.rawValue < $1.rawValue }
            if !allowStackExchange, sources.contains(.stackOverflow) { outcome.failed.append(.stackOverflow) }
            group.cancelAll()
        }
        return outcome
    }

    /// SearXNG on this Mac answers JSON (the stock image needs it enabled).
    public func searxngReady() async -> Bool {
        guard let url = WebRequests.searxng("test") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] != nil
    }

    private func takeStackExchangeRequests(_ count: Int) -> Bool {
        let today = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate])
        if today != stackExchangeDay { stackExchangeDay = today; stackExchangeCount = 0 }
        guard stackExchangeCount + count <= Self.stackExchangeDailyLimit else { return false }
        stackExchangeCount += count
        return true
    }

    // MARK: - Per source

    static func get(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(WebRequests.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maxPageBytes else { return nil }
        return data
    }

    static func fetch(_ source: WebSource, query: String, session: URLSession) async -> [WebDocument] {
        switch source {
        case .wikipedia:
            guard let url = WebRequests.wikipedia(query), let data = await get(url, session: session) else { return [] }
            return WebParsers.wikipedia(data)
        case .stackOverflow:
            guard let url = WebRequests.stackOverflowSearch(query), let data = await get(url, session: session) else { return [] }
            let questions = WebParsers.stackOverflowQuestions(data).prefix(3)
            guard let answersURL = WebRequests.stackOverflowAnswers(questions.map(\.answer)),
                  let answers = await get(answersURL, session: session) else { return [] }
            let bodies = WebParsers.stackOverflowAnswers(answers)
            return questions.compactMap { question in
                bodies[question.answer].map { WebDocument(title: question.title, url: question.link, text: $0, source: .stackOverflow) }
            }
        case .mdn:
            guard let url = WebRequests.mdnSearch(query), let data = await get(url, session: session),
                  let hit = WebParsers.mdnSearch(data).first, let pageURL = WebRequests.mdnPage(hit.path),
                  let page = URL(string: "https://developer.mozilla.org\(hit.path)") else { return [] }
            if let pageData = await get(pageURL, session: session), let document = WebParsers.mdnPage(pageData, page: page) {
                return [document]
            }
            return hit.summary.isEmpty ? [] : [WebDocument(title: hit.title, url: page, text: hit.summary, source: .mdn)]
        case .appleDocs:
            guard let urls = WebRequests.appleDocs(query), let data = await get(urls.data, session: session),
                  let document = WebParsers.appleDocs(data, page: urls.page) else { return [] }
            return [document]
        case .searxng:
            guard let url = WebRequests.searxng(query), let data = await get(url, session: session) else { return [] }
            let results = WebParsers.searxng(data).prefix(5)
            let seen = Set(results.map(\.url))
            var documents = results.filter { !$0.snippet.isEmpty }.prefix(3).map {
                WebDocument(title: $0.title, url: $0.url, text: $0.snippet, source: .searxng)
            }
            // The top two pages, read at once.
            let pages = await withTaskGroup(of: WebDocument?.self) { group in
                for result in results.prefix(2) where URLGuard.allows(result.url, seenIn: seen) {
                    group.addTask { await page(result.url, source: .searxng, session: session) }
                }
                var read: [WebDocument] = []
                for await page in group { if let page { read.append(page) } }
                return read
            }
            documents.insert(contentsOf: pages, at: 0)
            return documents
        }
    }

    static func page(_ url: URL, source: WebSource, session: URLSession) async -> WebDocument? {
        guard let data = await get(url, session: session),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let text = HTMLText.readable(html)
        guard text.count > 80 else { return nil }
        return WebDocument(title: HTMLText.title(in: html) ?? url.host ?? url.absoluteString, url: url, text: text, source: source)
    }
}
