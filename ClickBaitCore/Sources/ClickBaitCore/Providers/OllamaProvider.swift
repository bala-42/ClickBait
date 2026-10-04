import Foundation
import os

/// Local, private default: Ollama's `/api/chat` on this Mac.
public struct OllamaProvider: LLMProvider {
    /// Looks at the screen, points, explains and plans walkthroughs: the more accurate
    /// pointer (69% vs 46% on the parts benchmark) and the better planner (cross-app plans
    /// Qwen 2.5-VL got wrong, in ~3–8 s).
    public static let defaultModel = "qwen3.5:9b"
    /// Reads orders ("stash these in my documents") in ~0.1–0.7 s instead of ~1.8 s. The
    /// 3b, because the 7b didn't fit in memory beside the main model on a 24 GB Mac with apps
    /// open: Ollama unloaded one to load the other (~3 s each way).
    public static let defaultFastModel = "qwen2.5vl:3b"

    /// Models stay loaded while ClickBait runs (user's decision, 2026-10-04): no 3–5 s
    /// reload after a break. `unload()` lets them go when ClickBait quits.
    static let keepAlive = -1

    /// Frees both models (ClickBait is quitting). Waits at most `within`.
    public func unload(within limit: TimeInterval = 1.5) {
        let group = DispatchGroup()
        for name in [model] + (fastModel.map { [$0] } ?? []) {
            var request = URLRequest(url: Self.baseURL.appending(path: "api/generate"), timeoutInterval: limit)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "keep_alive": 0])
            group.enter()
            session.dataTask(with: request) { _, _, _ in group.leave() }.resume()
        }
        _ = group.wait(timeout: .now() + limit)
    }

    /// Set once loading the fast model pushed the main one out of memory: from then on
    /// (this run of the app) the main model answers everything.
    static let fastModelEvictsMain = OSAllocatedUnfairLock(initialState: false)
    /// Privacy rule: Ollama is only ever reached on localhost.
    public static let baseURL = URL(string: "http://localhost:11434")!

    public let model: String
    /// For order checks; nil uses `model` for everything.
    public let fastModel: String?
    private let session: URLSession

    public init(model: String, fastModel: String? = nil, session: URLSession = .shared) {
        self.model = model
        self.fastModel = (fastModel?.isEmpty ?? true) || fastModel == model ? nil : fastModel
        self.session = session
    }

    public var displayName: String { fastModel.map { "Ollama (\(model) + \($0))" } ?? "Ollama (\(model))" }

    public var coordinateScale: CoordinateScale { Self.coordinateScale(forModel: model) }

    /// Qwen 3 and 3.5 (Qwen3-VL's grounding) give positions as 0–1000 of the image.
    static func coordinateScale(forModel name: String) -> CoordinateScale {
        name.lowercased().hasPrefix("qwen3") ? .thousandths : .pixels
    }

    /// Which model answers: order checks go to the fast one (unless it doesn't fit).
    func model(for ask: AskRequest) -> String {
        guard ask.interpretOrder, let fastModel, !Self.fastModelEvictsMain.withLock({ $0 }) else { return model }
        return fastModel
    }

    /// The models Ollama has in memory now.
    func loadedModels() async -> [String] {
        let request = URLRequest(url: Self.baseURL.appending(path: "api/ps"), timeoutInterval: 2)
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// After the fast model answered: is the main one still loaded? If not, stop using
    /// the fast one (every switch would reload a model).
    func checkBothFit() async {
        guard fastModel != nil, !Self.fastModelEvictsMain.withLock({ $0 }) else { return }
        let loaded = await loadedModels()
        guard !loaded.isEmpty, !Self.isInstalled(model, among: loaded) else { return }
        Self.fastModelEvictsMain.withLock { $0 = true }
    }

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
                    if request.interpretOrder { await checkBothFit() }
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
        for wanted in [model] + (fastModel.map { [$0] } ?? []) where !Self.isInstalled(wanted, among: names) {
            throw LLMError.modelNotFound(wanted)
        }
    }

    /// Loads the model into memory (an empty generate request), which can take ~10 s
    /// cold. Errors are ignored: the real request reports them properly.
    public func warmUp() async {
        await load(model)
        guard let fastModel, !Self.fastModelEvictsMain.withLock({ $0 }) else { return }
        await load(fastModel)
        await checkBothFit()
        if Self.fastModelEvictsMain.withLock({ $0 }) { await load(model) }  // it pushed the main one out
    }

    private func load(_ name: String) async {
        var request = URLRequest(url: Self.baseURL.appending(path: "api/generate"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same context size as real requests, or Ollama reloads the model for the first one.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": name, "keep_alive": Self.keepAlive, "options": ["num_ctx": Self.contextTokens],
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
        let answering = model(for: ask)
        var ask = ask
        ask.coordinateScale = Self.coordinateScale(forModel: answering)
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.chatBody(for: ask, model: answering))
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
                    "properties": ["target": ["type": "string"], "instruction": ["type": "string"], "app": ["type": "string"],
                                   "type": ["type": "string"]],
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
            // Newer models (Qwen 3.5, Gemma 4) think before answering unless told not to:
            // ~10 s on a one-line answer, and the thinking can use up the whole reply budget.
            // Models that can't think ignore it.
            "think": false,
            // Keep the model in memory between questions; loading takes seconds.
            "keep_alive": Self.keepAlive,
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
