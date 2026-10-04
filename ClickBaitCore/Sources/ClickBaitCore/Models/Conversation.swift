/// One message in a bubble's conversation.
public struct ChatTurn: Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public var role: Role
    /// What's sent back to the model as this turn's content.
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    /// An assistant turn in the JSON shape the model is asked to produce, so earlier
    /// answers in the history look like the replies it should keep giving. Pointers are
    /// dropped: their coordinates belong to an older screenshot.
    public static func assistant(speech: String, code: String? = nil, language: String? = nil) -> ChatTurn {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        var json = "{\"speech\": \"\(escape(speech))\", \"pointers\": []"
        if let code { json += ", \"code\": \"\(escape(code))\", \"language\": \"\(escape(language ?? ""))\"" }
        return ChatTurn(role: .assistant, content: json + "}")
    }
}

/// The memory of one chat bubble: everything said in it, scoped to that bubble and
/// gone when it closes. Only text is kept — each new message carries a fresh
/// screenshot, older screenshots are never resent.
public struct Conversation: Equatable, Sendable {
    /// Exchanges (user + assistant) sent with each request. The first exchange — the
    /// original question or highlighted text — is always kept; the rest are the most
    /// recent ones. Keeps a local model fast as the chat grows.
    public static let maxExchanges = 10

    public private(set) var turns: [ChatTurn] = []

    public init() {}

    public var isEmpty: Bool { turns.isEmpty }
    /// The last answer's words: what "add it to my notes" means.
    public private(set) var lastAnswer: String?

    public mutating func append(user content: String, assistantSpeech: String, code: String? = nil, language: String? = nil) {
        if !assistantSpeech.isEmpty { lastAnswer = code.map { assistantSpeech + "\n" + $0 } ?? assistantSpeech }
        turns.append(ChatTurn(role: .user, content: content))
        turns.append(.assistant(speech: assistantSpeech, code: code, language: language))
    }

    /// The turns to send before the new message.
    public var history: [ChatTurn] {
        let limit = Self.maxExchanges * 2
        guard turns.count > limit else { return turns }
        return Array(turns.prefix(2)) + Array(turns.suffix(limit - 2))
    }
}
