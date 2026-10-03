import Foundation

/// Bring-your-own-key cloud provider: Anthropic Messages API over raw HTTP (there's no
/// official Swift SDK). Only used when the user picks it and has saved a key.
public struct AnthropicProvider: LLMProvider {
    public static let defaultModel = "claude-opus-5-5"
    static let baseURL = URL(string: "https://api.anthropic.com/v1")!
    static let apiVersion = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let model: String
    private let apiKey: String?
    private let session: URLSession

    public init(model: String, apiKey: String?, session: URLSession = .shared) {
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    public var displayName: String { "Anthropic (\(model))" }

    private static let unreachable = "Couldn't reach Anthropic. Check your internet connection."

    public func stream(_ request: AskRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
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
        var request = try authorizedRequest(url: Self.baseURL.appending(path: "messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        let options = Self.options(for: model)
        if options.fallbacks {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.messagesBody(for: ask, model: model))
        return request
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
        var body: [String: Any] = [
            "model": model,
            // Room for adaptive thinking plus a short JSON answer.
            "max_tokens": 4096,
            "stream": true,
            "system": Prompt.system(for: ask),
            // Earlier turns as text; only the newest message carries a screenshot.
            "messages": ask.history.map { ["role": $0.role.rawValue, "content": $0.content] as [String: Any] } + [[
                "role": "user",
                "content": (ask.screenshotJPEG.isEmpty ? [] : [[
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": ask.screenshotJPEG.base64EncodedString(),
                    ] as [String: Any],
                ] as [String: Any]]) + [["type": "text", "text": Prompt.userText(for: ask)]],
            ]],
        ]
        let options = options(for: model)
        if options.effort {
            // Spoken answers must start fast; low effort keeps thinking short.
            body["output_config"] = ["effort": "low"]
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
