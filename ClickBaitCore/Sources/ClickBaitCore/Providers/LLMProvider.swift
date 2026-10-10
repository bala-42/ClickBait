import Foundation

/// A model that looks at a screenshot and answers with `AssistantResponse` JSON.
///
/// `stream` yields raw text chunks as they arrive; the caller parses them (and can
/// start speaking before the reply is complete).
public protocol LLMProvider: Sendable {
    /// Shown to the user, e.g. "Ollama (qwen2.5vl:7b)".
    var displayName: String { get }

    func stream(_ request: AskRequest) -> AsyncThrowingStream<String, Error>

    /// Cheap check that the provider is reachable and configured. Never generates text.
    func checkConnection() async throws

    /// Called when the user starts talking, so slow-to-load models are ready by the
    /// time the question arrives. Must never send user content.
    func warmUp() async

    /// How the model that answers questions about the screen writes positions.
    var coordinateScale: CoordinateScale { get }

    /// Deadlines for secondary requests such as tutorial classification and tour labels.
    func timeout(for operation: ProviderOperation) -> Duration
}

extension LLMProvider {
    public var coordinateScale: CoordinateScale { .pixels }

    public func timeout(for operation: ProviderOperation) -> Duration {
        switch operation {
        case .interpretOrder: .seconds(8)
        case .classifyRequest: .seconds(3)
        case .selectElement: .seconds(5)
        case .planTutorialTextOnly: .seconds(15)
        case .planTutorialWithScreenshot: .seconds(25)
        case .labelTourParts: .seconds(20)
        }
    }
}

public enum LLMError: LocalizedError, Equatable {
    case missingAPIKey
    case unreachable(String)
    case modelNotFound(String)
    case http(status: Int, message: String)
    case refusal(category: String?)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your Anthropic API key in Settings, or switch to Ollama."
        case .unreachable(let detail):
            detail
        case .modelNotFound(let model):
            "The model “\(model)” isn't available."
        case .http(let status, let message):
            status == 401 ? "The API key was rejected. Check it in Settings." : "The model service returned an error (\(status)): \(message)"
        case .refusal:
            "The model declined to answer this one."
        case .invalidResponse(let detail):
            "The model sent something unexpected: \(detail)"
        }
    }
}

/// A bounded deadline for the small secondary requests that complete a screen answer.
/// Network providers need more room for round trips than an on-device model.
public enum ProviderOperation: Sendable, Equatable {
    case interpretOrder
    case classifyRequest
    case selectElement
    case planTutorialTextOnly
    case planTutorialWithScreenshot
    case labelTourParts
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
