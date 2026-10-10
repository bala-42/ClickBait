import Foundation

/// A model that looks at a screenshot and answers with `AssistantResponse` JSON.
///
/// `stream` yields raw text chunks as they arrive; the caller parses them (and can
/// start speaking before the reply is complete).
public protocol LLMProvider: Sendable {
    /// Shown to the user, e.g. "Ollama (qwen3.5:9b)".
    var displayName: String { get }

    func stream(_ request: AskRequest) -> AsyncThrowingStream<String, Error>

    /// Cheap check that the provider is reachable and configured. Never generates text.
    func checkConnection() async throws

    /// Called when the user starts talking, so slow-to-load models are ready by the
    /// time the question arrives. Must never send user content.
    func warmUp() async

    /// How the model that answers questions about the screen writes positions.
    var coordinateScale: CoordinateScale { get }
}

extension LLMProvider {
    public var coordinateScale: CoordinateScale { .pixels }
}

public enum LLMError: LocalizedError, Equatable {
    case unreachable(String)
    case modelNotFound(String)
    case http(status: Int, message: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            detail
        case .modelNotFound(let model):
            "The model “\(model)” isn't available."
        case .http(let status, let message):
            "The model service returned an error (\(status)): \(message)"
        case .invalidResponse(let detail):
            "The model sent something unexpected: \(detail)"
        }
    }
}

/// The small secondary requests that complete a screen answer, each with a deadline so a
/// slow one never holds up the answer.
public enum ProviderOperation: Sendable, Equatable {
    case interpretOrder
    case classifyRequest
    case selectElement
    case planTutorialTextOnly
    case planTutorialWithScreenshot
    case labelTourParts

    public var timeout: Duration {
        switch self {
        case .interpretOrder: .seconds(8)
        case .classifyRequest: .seconds(3)
        case .selectElement: .seconds(5)
        case .planTutorialTextOnly: .seconds(15)
        case .planTutorialWithScreenshot: .seconds(25)
        case .labelTourParts: .seconds(20)
        }
    }
}

extension LLMProvider {
    public func warmUp() async {}

    /// Collects the whole reply. Handy for tests and non-streaming callers.
    public func complete(_ request: AskRequest) async throws -> String {
        var text = ""
        for try await chunk in stream(request) { text += chunk }
        return text
    }
}
