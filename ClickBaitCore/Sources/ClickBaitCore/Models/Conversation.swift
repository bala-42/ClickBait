import Foundation

/// One message in a bubble's conversation.
public struct ChatTurn: Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public var role: Role
    /// What's sent back to the model as this turn's content.
    public var content: String
    /// The screenshot sent with it: only the first question's, and only when a follow-up
    /// reuses it (`Conversation.history(reusingScreen:)`).
    public var images: [Data] = []

    public init(role: Role, content: String, images: [Data] = []) {
        self.role = role
        self.content = content
        self.images = images
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

    /// The first question's screenshot, kept so a follow-up on an unchanged screen sends no
    /// new one: Ollama has already read it (it caches the start of a conversation), and a
    /// follow-up starts ~1.3 s sooner (1.6 s → 0.3 s measured, 2026-10-25). `thumbnail` is
    /// `ScreenChange.thumbnail` of it.
    public struct Screen: Equatable, Sendable {
        public let jpeg: Data
        public let width: Int
        public let height: Int
        public let thumbnail: [UInt8]
        public init(jpeg: Data, width: Int, height: Int, thumbnail: [UInt8]) {
            self.jpeg = jpeg
            self.width = width
            self.height = height
            self.thumbnail = thumbnail
        }
    }
    public private(set) var screen: Screen?
    /// The last answer was given without the screen (a question about the world): a
    /// follow-up that doesn't name the screen stays off it too (`ScreenNeed.followUpNeedsScreen`).
    public var lastOffScreen = false

    public init() {}

    /// Keeps the first question's screenshot (only after the first exchange).
    public mutating func remember(_ screen: Screen) {
        guard turns.count == 2, self.screen == nil, !screen.jpeg.isEmpty else { return }
        self.screen = screen
    }

    /// The history with the first question's screenshot back in its place: the same start
    /// as the first request, so Ollama reuses what it read.
    public var historyReusingScreen: [ChatTurn] {
        var turns = history
        guard let screen, !turns.isEmpty, turns[0].role == .user else { return turns }
        turns[0].images = [screen.jpeg]
        return turns
    }

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
