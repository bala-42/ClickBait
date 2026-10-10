import Foundation

/// Bring-your-own-key cloud provider: Anthropic Messages API over raw HTTP (there's no
/// official Swift SDK). Only used when the user picks it and has saved a key.
public struct AnthropicProvider: LLMProvider {
    public static let defaultModel = "claude-opus-5-5"
    static let baseURL = URL(string: "https://api.anthropic.com/v1")!
    static let apiVersion = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let webSearchMaxUses = 1
    static let webSearchMaxContinuations = 2

    public let model: String
    private let apiKey: String?
    private let session: URLSession

    public init(model: String, apiKey: String?, session: URLSession = .shared) {
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    public var displayName: String { "Anthropic (\(model))" }
    public var coordinateScale: CoordinateScale { .pixels }

    public func timeout(for operation: ProviderOperation) -> Duration {
        switch operation {
        case .interpretOrder: .seconds(12)
        case .classifyRequest: .seconds(8)
        case .selectElement: .seconds(10)
        case .planTutorialTextOnly: .seconds(25)
        case .planTutorialWithScreenshot: .seconds(40)
        case .labelTourParts: .seconds(90)
        }
    }

    private static let unreachable = "Couldn't reach Anthropic. Check your internet connection."

    public func stream(_ request: AskRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if !request.markNames.isEmpty {
                        let text = try await completeWebSearch(request)
                        if !text.isEmpty { continuation.yield(text) }
                        continuation.finish()
                        return
                    }

                    let lines = try await HTTPStreaming.lines(
                        for: try makeMessagesRequest(request),
                        session: session,
                        unreachableMessage: Self.unreachable,
                        errorMessage: { [model] status, body in Self.error(status: status, body: body, model: model) }
                    )
                    var parser = SSEParser()
                    func handle(_ event: SSEParser.Event) throws -> Bool {
                        switch try AnthropicStreamDecoder.decode(event) {
                        case .text(let text): continuation.yield(text)
                        case .done: return true
                        case .none: break
                        }
                        return false
                    }
                    for try await line in lines {
                        // `lines` drops blank lines, so every `event:` line starts a new event.
                        if line.hasPrefix("event:"), let event = parser.flush(), try handle(event) { break }
                        if let event = parser.consume(line: line), try handle(event) { break }
                    }
                    if let event = parser.flush() { _ = try handle(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Validates the key and model with the Models API — no tokens are generated.
    public func checkConnection() async throws {
        var request = try authorizedRequest(url: Self.baseURL.appending(path: "models/\(model)"))
        request.timeoutInterval = 10
        let (data, status) = try await HTTPStreaming.data(for: request, session: session, unreachableMessage: Self.unreachable)
        guard status == 200 else { throw Self.error(status: status, body: data, model: model) }
    }

    func makeMessagesRequest(_ ask: AskRequest) throws -> URLRequest {
        try makeMessagesRequest(body: Self.messagesBody(for: ask, model: model))
    }

    private func makeMessagesRequest(body: [String: Any]) throws -> URLRequest {
        var request = try authorizedRequest(url: Self.baseURL.appending(path: "messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        let options = Self.options(for: model)
        if options.fallbacks {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// A red tour is a follow-up, so it can finish as a single result after a bounded web
    /// search. Anthropic may pause a long server-side search loop; replay its assistant
    /// content unchanged, with the same search tool, until it finishes or reaches the cap.
    private func completeWebSearch(_ ask: AskRequest) async throws -> String {
        var body = Self.messagesBody(for: ask, model: model)
        var continuations = 0

        while true {
            try Task.checkCancellation()
            let request = try makeMessagesRequest(body: body)
            let (data, status) = try await HTTPStreaming.data(for: request, session: session,
                                                               unreachableMessage: Self.unreachable)
            guard (200..<300).contains(status) else { throw Self.error(status: status, body: data, model: model) }
            let message = try Self.decodeMessageResponse(data)

            if message.stopReason == "pause_turn" {
                guard continuations < Self.webSearchMaxContinuations else {
                    throw LLMError.invalidResponse("Internet Mode search took too long to finish.")
                }
                body = Self.continuationBody(body, assistantContent: message.content)
                continuations += 1
                continue
            }

            guard message.stopReason == "end_turn" || message.stopReason == "stop_sequence" else {
                throw LLMError.invalidResponse("Internet Mode ended before it finished matching the marked parts.")
            }
            let text = message.content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LLMError.invalidResponse("Internet Mode returned no part labels.")
            }
            return text
        }
    }

    static func decodeMessageResponse(_ data: Data) throws -> (content: [[String: Any]], stopReason: String) {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawContent = response["content"] as? [Any],
              let stopReason = response["stop_reason"] as? String else {
            throw LLMError.invalidResponse("Anthropic returned an unreadable message.")
        }
        let content = rawContent.compactMap { $0 as? [String: Any] }
        guard content.count == rawContent.count else {
            throw LLMError.invalidResponse("Anthropic returned an unreadable message block.")
        }
        if stopReason == "refusal" {
            let details = response["stop_details"] as? [String: Any]
            throw LLMError.refusal(category: details?["category"] as? String)
        }
        return (content, stopReason)
    }

    static func continuationBody(_ body: [String: Any], assistantContent: [[String: Any]]) -> [String: Any] {
        var continued = body
        var messages = body["messages"] as? [[String: Any]] ?? []
        messages.append(["role": "assistant", "content": assistantContent])
        continued["messages"] = messages
        return continued
    }

    private func authorizedRequest(url: URL) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    /// Request features that only some models accept; sending them to others is a 400.
    static func options(for model: String) -> (effort: Bool, fallbacks: Bool) {
        let fallbackModels: Set = ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]
        let effortPrefixes = ["claude-fable-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
                              "claude-sonnet-5", "claude-sonnet-4-6"]
        return (effortPrefixes.contains { model.hasPrefix($0) }, fallbackModels.contains(model))
    }

    static func messagesBody(for ask: AskRequest, model: String) -> [String: Any] {
        let useWebSearch = !ask.markNames.isEmpty
        var body: [String: Any] = [
            "model": model,
            // Leave room for reasoning. Red marker matching gets a larger ceiling below.
            "max_tokens": ask.markNames.isEmpty ? 8192 : 16_384,
            // The marker follow-up is not spoken; wait for the whole answer so a paused
            // server-side search can be resumed with the exact assistant content.
            "stream": !useWebSearch,
            "system": Prompt.system(for: ask),
            // Earlier turns as text; only the newest message carries a screenshot.
            "messages": ask.history.map { ["role": $0.role.rawValue, "content": $0.content] as [String: Any] } + [[
                "role": "user",
                "content": ([ask.screenshotJPEG] + (ask.contextJPEG.map { [$0] } ?? [])).filter { !$0.isEmpty }.map { image in
                    [
                        "type": "image",
                        "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()] as [String: Any],
                    ] as [String: Any]
                } + [["type": "text", "text": Prompt.userText(for: ask)]],
            ]],
        ]
        let options = options(for: model)
        if useWebSearch {
            body["tools"] = [[
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": webSearchMaxUses,
                "allowed_callers": ["direct"],
            ]]
        }
        if options.effort, !ask.markNames.isEmpty {
            // Spend more reasoning on the red tour's visual matching step, where a wrong
            // label sends the cursor to the wrong part. Ordinary asks use the model default.
            body["output_config"] = ["effort": "high"]
        }
        if options.fallbacks {
            // Re-run a wrongly declined request on Anthropic's recommended model.
            body["fallbacks"] = "default"
        }
        return body
    }

    static func error(status: Int, body: Data, model: String) -> LLMError {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        if status == 404 { return .modelNotFound(model) }
        return .http(status: status, message: message)
    }
}
