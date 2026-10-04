import Foundation

/// Local, private default: Ollama's `/api/chat` on this Mac.
public struct OllamaProvider: LLMProvider {
    public static let defaultModel = "qwen2.5vl:7b"
    /// Privacy rule: Ollama is only ever reached on localhost.
    public static let baseURL = URL(string: "http://localhost:11434")!

    public let model: String
    private let session: URLSession

    public init(model: String, session: URLSession = .shared) {
        self.model = model
        self.session = session
    }

    public var displayName: String { "Ollama (\(model))" }

    private static let unreachable = "Ollama isn't running. Open the Ollama app, then try again."

    public func stream(_ request: AskRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let lines = try await HTTPStreaming.lines(
                        for: try makeChatRequest(request),
                        session: session,
                        unreachableMessage: Self.unreachable,
                        errorMessage: { [model] status, body in Self.error(status: status, body: body, model: model) }
                    )
                    for try await line in lines {
                        guard let chunk = try OllamaStreamDecoder.decode(line: line) else { continue }
                        if !chunk.text.isEmpty { continuation.yield(chunk.text) }
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func checkConnection() async throws {
        let request = URLRequest(url: Self.baseURL.appending(path: "api/tags"), timeoutInterval: 5)
        let (data, status) = try await HTTPStreaming.data(for: request, session: session, unreachableMessage: Self.unreachable)
        guard status == 200 else { throw LLMError.http(status: status, message: "Ollama didn't list its models") }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let names = (json?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        guard Self.isInstalled(model, among: names) else { throw LLMError.modelNotFound(model) }
    }

    /// Loads the model into memory (an empty generate request), which can take ~10 s
    /// cold. Errors are ignored: the real request reports them properly.
    public func warmUp() async {
        var request = URLRequest(url: Self.baseURL.appending(path: "api/generate"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same context size as real requests, or Ollama reloads the model for the first one.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "keep_alive": "15m", "options": ["num_ctx": Self.contextTokens],
        ])
        _ = try? await session.data(for: request)
    }

    /// `llava` matches `llava:latest`; tagged names must match exactly.
    static func isInstalled(_ model: String, among names: [String]) -> Bool {
        let wanted = model.contains(":") ? model : model + ":latest"
        return names.contains(wanted) || names.contains(model)
    }

    func makeChatRequest(_ ask: AskRequest) throws -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appending(path: "api/chat"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.chatBody(for: ask, model: model))
        return request
    }

    /// The screenshot alone is ~1,400 tokens and the element list can add ~2,000; Ollama's
    /// default of 4,096 overflowed (an error, or worse, the instructions silently cut).
    static let contextTokens = 8192
    /// Replies are a few sentences plus maybe some code. A cap stops a runaway reply
    /// (one ran to 10,000 characters and 2 minutes) from blocking the next question.
    static let maxReplyTokens = 800
    /// Six parts fit easily; the 7B model otherwise repeats "Optic chiasm" until the cap.
    static let partsReplyTokens = 320

    static func options(for ask: AskRequest) -> [String: Any] {
        var options: [String: Any] = ["temperature": 0.1, "num_ctx": contextTokens, "num_predict": maxReplyTokens]
        if ask.listParts { options["num_predict"] = partsReplyTokens }
        return options
    }

    /// The exact shape of a parts reply, enforced by Ollama's structured output: numbers
    /// for x and y, a name for each, at most six — no garbled positions, no endless lists.
    /// Structured output for the requests that have a fixed shape.
    static func schema(for ask: AskRequest) -> [String: Any]? {
        if ask.listParts { return partsSchema }
        if ask.planTutorial { return tutorialSchema }
        if ask.tutorialCheck != nil { return progressSchema }
        return nil
    }

    static var tutorialSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "speech": ["type": "string"],
            "app": ["type": "string"],
            "steps": [
                "type": "array",
                "maxItems": TutorialPlan.maxSteps,
                "items": [
                    "type": "object",
                    "properties": ["target": ["type": "string"], "instruction": ["type": "string"], "app": ["type": "string"]],
                    "required": ["target", "instruction"],
                ] as [String: Any],
            ] as [String: Any],
        ],
        "required": ["speech", "steps"],
    ] }

    static var progressSchema: [String: Any] { [
        "type": "object",
        "properties": ["next_step": ["type": "integer"], "done": ["type": "boolean"]],
        "required": ["next_step", "done"],
    ] }

    static var partsSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "parts": [
                "type": "array",
                "maxItems": 6,
                "items": [
                    "type": "object",
                    "properties": ["x": ["type": "number"], "y": ["type": "number"], "label": ["type": "string"]],
                    "required": ["x", "y", "label"],
                ] as [String: Any],
            ] as [String: Any],
        ],
        "required": ["parts"],
    ] }

    static func chatBody(for ask: AskRequest, model: String) -> [String: Any] {
        var message: [String: Any] = ["role": "user", "content": Prompt.userText(for: ask)]
        let images = ([ask.screenshotJPEG] + (ask.contextJPEG.map { [$0] } ?? [])).filter { !$0.isEmpty }
        if !images.isEmpty { message["images"] = images.map { $0.base64EncodedString() } }
        return [
            "model": model,
            "stream": true,
            "format": schema(for: ask) ?? "json",
            // Keep the model in memory between questions; loading takes seconds.
            "keep_alive": "15m",
            "options": options(for: ask),
            "messages": [["role": "system", "content": Prompt.system(for: ask)]]
                + ask.history.map { ["role": $0.role.rawValue, "content": $0.content] as [String: Any] }
                + [message],
        ]
    }

    static func error(status: Int, body: Data, model: String) -> LLMError {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = json?["error"] as? String ?? String(decoding: body.prefix(300), as: UTF8.self)
        if status == 404 { return .modelNotFound(model) }
        return .http(status: status, message: message)
    }
}
