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

    public init(speech: String, pointers: [Pointer] = []) {
        self.speech = speech
        self.pointers = pointers
    }
}
