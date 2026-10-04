/// A point the assistant wants to highlight, in the downscaled screenshot's pixel space
/// (origin top-left).
public struct Pointer: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var label: String

    public init(x: Double, y: Double, label: String) {
        self.x = x
        self.y = y
        self.label = label
    }
}

/// The structured reply every `LLMProvider` is asked to produce.
public struct AssistantResponse: Codable, Equatable, Sendable {
    public var speech: String
    public var pointers: [Pointer]
    /// Code, a formula or a command, kept out of `speech` so it's shown but never read
    /// aloud (small models drop code they're asked to embed inside the speech string).
    public var code: String?
    public var language: String?
    /// An order the model recognised that the rules didn't. Only a proposal: it's
    /// checked against `ActionCatalog`, and risky ones are confirmed by the user.
    public var action: ActionRequest?

    public init(speech: String, pointers: [Pointer] = [], code: String? = nil, language: String? = nil,
                action: ActionRequest? = nil) {
        self.speech = speech
        self.pointers = pointers
        self.code = code
        self.language = language
        self.action = action
    }

    /// What the chat shows: the words, then the code as a fenced block.
    public var displayText: String {
        guard let code, !code.isEmpty else { return speech }
        // Models sometimes repeat the code fenced inside "speech" too: show it once.
        let words = speech.contains("```") ? MessageFormat.spokenText(speech) : speech
        return words + "\n```" + (language ?? "") + "\n" + code + "\n```"
    }
}
