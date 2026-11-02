import Foundation
import os

/// Local, private default: Ollama's `/api/chat` on this Mac.
public struct OllamaProvider: LLMProvider {
    /// Looks at the screen, points, explains and plans walkthroughs: the more accurate
    /// pointer (69% vs 46% on the parts benchmark) and the better planner (cross-app plans
    /// Qwen 2.5-VL got wrong, in ~3–8 s).
    public static let defaultModel = "qwen3.5:9b"
    /// A second, faster model for order checks; empty by default (one model). On a 24 GB
    /// Mac with apps open, keeping qwen2.5vl:3b loaded too (4.6 GB) pushed macOS into
    /// swapping, and both models ran at half speed (a 20 s answer). Settable in Settings.
    public static let defaultFastModel = ""

    /// Models stay loaded while ClickBait runs (user's decision, 2026-10-04): no 3–5 s
    /// reload after a break. `unload()` lets them go when ClickBait quits.
    public static let keepAlive = -1

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
                // Your question first: a dock answer waits to start while one is waiting
                // (`ModelTurns`); a foreground one counts itself until it's done.
                let background = request.turn?.isBackground ?? false
                if background { await ModelTurns.waitForTurn() } else { ModelTurns.enter() }
                defer { if !background { ModelTurns.leave() } }
                do {
                    let lines = try await HTTPStreaming.lines(
                        for: try makeChatRequest(request),
                        session: session,
                        unreachableMessage: Self.unreachable,
                        errorMessage: { [model] status, body in Self.error(status: status, body: body, model: model) }
                    )
                    // A code answer comes as Markdown, handed on as answer JSON as it streams:
                    // its words at once, its code when complete (`CodeAnswer.Stream`).
                    var codeStream = CodeAnswer.Stream()
                    for try await line in lines {
                        guard let chunk = try OllamaStreamDecoder.decode(line: line) else { continue }
                        let piece = request.codeAnswer ? codeStream.feed(chunk.text) : chunk.text
                        if !piece.isEmpty { continuation.yield(piece) }
                        if chunk.done { break }
                    }
                    if request.codeAnswer { continuation.yield(codeStream.finish()) }
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

    /// How the answering model is doing, shown as a dot in the menu and the notch.
    public enum Health: Equatable, Sendable {
        /// Loaded: answers start right away.
        case ready
        /// Installed but not in memory: the first answer waits for it to load.
        case asleep
        /// Ollama runs, but this model isn't pulled.
        case missing(String)
        /// Ollama isn't running.
        case unreachable
    }

    /// Asks Ollama what it has (two quick local requests; nothing is loaded).
    public func health() async -> Health {
        let request = URLRequest(url: Self.baseURL.appending(path: "api/tags"), timeoutInterval: 2)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .unreachable }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let installed = (json?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return Self.health(model: model, installed: installed, loaded: await loadedModels())
    }

    static func health(model: String, installed: [String], loaded: [String]) -> Health {
        guard isInstalled(model, among: installed) else { return .missing(model) }
        return isInstalled(model, among: loaded) ? .ready : .asleep
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
    public static let contextTokens = 8192
    /// Replies are a few sentences plus maybe some code. A cap stops a runaway reply
    /// (one ran to 10,000 characters and 2 minutes) from blocking the next question; 800
    /// cut whole programs ("write a snake game") off mid-JSON, so the code was lost.
    static let maxReplyTokens = 2048
    /// Six parts fit easily; the 7B model otherwise repeats "Optic chiasm" until the cap.
    static let partsReplyTokens = 320

    static func options(for ask: AskRequest) -> [String: Any] {
        var options: [String: Any] = ["temperature": 0.1, "num_ctx": contextTokens, "num_predict": maxReplyTokens]
        if ask.listParts { options["num_predict"] = partsReplyTokens }
        if ask.lookupQuery { options["num_predict"] = 60 }
        if ask.suggestNextAfter != nil { options["num_predict"] = 60 }
        if ask.morningBrief != nil { options["num_predict"] = 120; options["temperature"] = 0.4 }
        if ask.routeIntent { options["num_predict"] = 40 }
        if let heard = ask.dictation { options["num_predict"] = 40 + heard.count / 2 }
        if ask.writeInstruction != nil { options["num_predict"] = 700; options["temperature"] = 0.4 }
        // ~9 tokens a mark ("12": "Neptune",); 15 marks took 138.
        if !ask.markNames.isEmpty { options["num_predict"] = max(partsReplyTokens, ask.markCount * 14) }
        return options
    }

    /// The exact shape of a parts reply, enforced by Ollama's structured output: numbers
    /// for x and y, a name for each, at most six — no garbled positions, no endless lists.
    /// Structured output for the requests that have a fixed shape.
    static func schema(for ask: AskRequest) -> [String: Any]? {
        if ask.listParts { return partsSchema }
        if !ask.markNames.isEmpty { return marksSchema(for: ask) }
        if ask.pickElement { return pickSchema }
        if ask.sortRequest { return sortSchema }
        if ask.routeIntent { return routeSchema }
        if ask.planTutorial { return tutorialSchema }
        if ask.tutorialCheck != nil { return progressSchema }
        if ask.dictation != nil || ask.writeInstruction != nil {
            return ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
        }
        if ask.lookupQuery { return ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]] }
        if ask.morningBrief != nil { return ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]] }
        if ask.suggestNextAfter != nil {
            return ["type": "object",
                    "properties": ["next": ["type": "array", "maxItems": NextSuggestions.maxCount, "items": ["type": "string"]]],
                    "required": ["next"]]
        }
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

    /// Matches `Prompt.pickSystem`: several ids in order, or none ({"ids": []}) when nothing fits.
    static var pickSchema: [String: Any] { [
        "type": "object",
        "properties": ["ids": ["type": "array", "maxItems": 3, "items": ["type": "integer"]]],
        "required": ["ids"],
    ] }

    static var sortSchema: [String: Any] { [
        "type": "object",
        "properties": ["kind": ["type": "string", "enum": ["steps", "answer"]]],
        "required": ["kind"],
    ] }

    static var routeSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "intent": ["type": "string", "enum": IntentRouter.Intent.allCases.map(\.rawValue)],
            "app": ["type": "string"],
        ] as [String: Any],
        "required": ["intent", "app"],
    ] }

    static var progressSchema: [String: Any] { [
        "type": "object",
        "properties": ["next_step": ["type": "integer"], "done": ["type": "boolean"]],
        "required": ["next_step", "done"],
    ] }

    /// One key per mark ("1"…"N"), each one of the names or "none".
    static func marksSchema(for ask: AskRequest) -> [String: Any] {
        let keys = (1...max(ask.markCount, 1)).map(String.init)
        let value: [String: Any] = ["type": "string", "enum": ask.markNames + ["none"]]
        return ["type": "object", "properties": Dictionary(uniqueKeysWithValues: keys.map { ($0, value) }), "required": keys]
    }

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
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            // Newer models (Qwen 3.5, Gemma 4) think before answering unless told not to:
            // ~10 s on a one-line answer, and the thinking can use up the whole reply budget.
            // Models that can't think ignore it.
            "think": false,
            // Keep the model in memory between questions; loading takes seconds.
            "keep_alive": Self.keepAlive,
            "options": options(for: ask),
            "messages": [["role": "system", "content": Prompt.system(for: ask)]]
                + ask.history.map { turn -> [String: Any] in
                    var message: [String: Any] = ["role": turn.role.rawValue, "content": turn.content]
                    if !turn.images.isEmpty { message["images"] = turn.images.map { $0.base64EncodedString() } }
                    return message
                }
                + [message],
        ]
        if !ask.codeAnswer { body["format"] = schema(for: ask) ?? "json" }  // Markdown, see `CodeAnswer`
        return body
    }

    static func error(status: Int, body: Data, model: String) -> LLMError {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = json?["error"] as? String ?? String(decoding: body.prefix(300), as: UTF8.self)
        if status == 404 { return .modelNotFound(model) }
        return .http(status: status, message: message)
    }
}
