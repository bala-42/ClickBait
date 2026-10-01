import Foundation

/// Server-Sent Events, fed one line at a time (as `URLSession.AsyncBytes.lines`
/// delivers them). Emits an event when a blank line ends it.
public struct SSEParser: Sendable {
    public struct Event: Equatable, Sendable {
        public var name: String?
        public var data: String
    }

    private var name: String?
    private var dataLines: [String] = []

    public init() {}

    /// Returns a completed event, if this line finished one.
    public mutating func consume(line: String) -> Event? {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") { return nil }  // comment / keep-alive
        let (field, value) = Self.split(line)
        switch field {
        case "event": name = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    /// Call at end of stream: some servers (and `lines`) drop the final blank line.
    public mutating func flush() -> Event? {
        defer { name = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        return Event(name: name, data: dataLines.joined(separator: "\n"))
    }

    private static func split(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (String(line[..<colon]), String(value))
    }
}

/// Anthropic Messages streaming events → text, per the documented SSE shapes.
public enum AnthropicStreamDecoder {
    public enum Output: Equatable {
        case text(String)
        case done
        case none
    }

    public static func decode(_ event: SSEParser.Event) throws -> Output {
        guard let json = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
              let type = json["type"] as? String
        else { return .none }

        switch type {
        case "content_block_delta":
            // Thinking deltas are skipped: only the visible answer is spoken.
            guard let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return .none }
            return .text(text)
        case "message_delta":
            let delta = json["delta"] as? [String: Any]
            if delta?["stop_reason"] as? String == "refusal" {
                let details = delta?["stop_details"] as? [String: Any] ?? json["stop_details"] as? [String: Any]
                throw LLMError.refusal(category: details?["category"] as? String)
            }
            return .none
        case "message_stop":
            return .done
        case "error":
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? event.data
            throw LLMError.invalidResponse(message)
        default:
            return .none
        }
    }
}

/// Ollama `/api/chat` streaming: one JSON object per line.
public enum OllamaStreamDecoder {
    public static func decode(line: String) throws -> (text: String, done: Bool)? {
        guard !line.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw LLMError.invalidResponse("unreadable line from Ollama")
        }
        if let error = json["error"] as? String {
            throw LLMError.invalidResponse(error)
        }
        let message = json["message"] as? [String: Any]
        let text = message?["content"] as? String ?? ""
        let done = json["done"] as? Bool ?? false
        return (text, done)
    }
}
